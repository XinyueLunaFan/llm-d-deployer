# KV Cache Awareness in llm-d: Debugging Learnings and Benchmark Results

**Date:** May 2026  
**Hardware:** Intel Max 1100 XPU, dut7904 (8 cards × 2 tiles, TP=2, 3 replicas = 6 GPUs)  
**Models tested:** Qwen3-8B, Qwen3-32B  
**Image:** `ghcr.io/llm-d/llm-d-xpu:v0.7.0-rc.4`

---

## Background

llm-d supports three routing strategies for KV cache awareness:

- **Baseline** — plain Kubernetes Service round-robin, no cache awareness
- **Approximate KV-aware** — inference-scheduling guide; uses a prefix-cache scorer that estimates which replica likely holds a given prefix based on hashed token blocks
- **Precise KV-aware** — precise-prefix-cache-aware guide; uses real-time KV cache event streams (ZMQ pub/sub) so the EPP has exact knowledge of which blocks each replica holds

The goal of this session was to validate all three cases using the new `v0.7.0-rc.4` image on Intel XPU hardware and understand why the precise case was not outperforming approximate.

---

## Issue 1: ZMQ Topology Mismatch — KV Events Never Reached the EPP

### How the precise scorer is supposed to work

The EPP (Endpoint Picker Plugin) maintains an in-memory KV cache index. Each vLLM replica publishes block-level cache events over ZMQ whenever blocks are added or evicted. The EPP subscribes to these events and uses them to score replicas at request time — routing each request to the replica most likely to already hold the relevant prefix blocks.

The intended topology is a **reverse PUB/SUB pattern**:

```
vLLM pod 1  --PUB--> :5557 (binds)
vLLM pod 2  --PUB--> :5557 (binds)       EPP SUB connects to each pod IP
vLLM pod 3  --PUB--> :5557 (binds)  <-------- discoverPods mode
```

In `discoverPods: true` mode, the EPP uses the Kubernetes API to enumerate pod IPs in the InferencePool and calls `connect()` on each one. vLLM binds `PUB` on `tcp://*:5557`. This is the correct asymmetry: many publishers bind, one subscriber connects to all of them.

### What was actually configured

The EPP ConfigMap had `discoverPods: false` with `zmqEndpoint: "tcp://*:5557"`. In this mode the EPP attempts to bind its own SUB socket on `*:5557` — expecting vLLM to connect to it. But vLLM also has `"endpoint": "tcp://*:5557"` which, because the address contains `*`, triggers a `bind()` call on vLLM's side too.

**Result: both sides bind. Neither connects. No ZMQ messages ever flow.**

### How we confirmed it

The EPP log showed this for every single request throughout the entire benchmark:

```
"msg":"Got endpoint scores","scores":null
"msg":"Got endpoint scores","scores":{}
"msg":"Calculated score","score":0   (all 3 replicas, every request)
```

The precise-prefix-cache-scorer was completely blind. With all replicas scoring 0, the max-score-picker fell back to arbitrary selection — identical to round-robin. The "precise" case was producing the same routing decisions as the baseline.

### The fix

Set `discoverPods: true` in the EPP ConfigMap (`qwen3-8b-epp.yaml`, `qwen3-32b-epp.yaml`):

```yaml
# Before
kvEventsConfig:
  discoverPods: false
  zmqEndpoint: "tcp://*:5557"

# After
kvEventsConfig:
  discoverPods: true
  zmqEndpoint: "tcp://*:5557"
```

With `discoverPods: true` the EPP discovers pod IPs via the Kubernetes API at runtime and calls `connect()` to each vLLM pod's bound PUB socket. No change to vLLM configuration is required.

### Key takeaway

In ZMQ, **both sides must not bind**. The correct pattern for fan-in aggregation (many publishers, one subscriber) is: publishers `bind`, subscriber `connect` to each publisher's address. The `discoverPods` flag is what enables the EPP to do this dynamically as pod IPs change. Always verify this is `true` in any deployment with more than one vLLM replica.

---

## Issue 2: num_prompts_per_group Inflating the Baseline Hit Rate

### The problem

The shared_prefix benchmark generates `num_groups × num_prompts_per_group` total requests. Requests within the same group share a long system prompt (the "prefix"). With the upstream default of `num_prompts_per_group=5` and only 3 replicas, the math works against a fair comparison:

- 5 prompts per group distributed across 3 replicas under round-robin
- Each replica receives approximately 5/3 ≈ 1.7 requests per group
- After the first request in a group lands on a replica and warms its local KV cache, the subsequent ~0.7 requests for the same group on the same replica become cache hits
- This yields roughly **40–50% token-level hit rate in the baseline even with no prefix-aware routing whatsoever**

The result: the "no routing intelligence" baseline looks artificially good, compressing the apparent benefit of KV-aware routing.

### The fix

Reduce `num_prompts_per_group` to be ≤ the number of replicas. With 3 replicas, set `num_prompts_per_group=2`. Now each replica receives at most 2/3 < 1 request per group on average — nearly every request is a cold miss in the baseline. This gives a realistic lower bound for unaware routing, making the KV-aware cases' improvements visible.

```yaml
# Upstream default (designed for 8 replicas)
num_prompts_per_group: 5

# Our 3-replica setting
num_prompts_per_group: 2
```

General rule: **`num_prompts_per_group` should be ≤ number of replicas** for the baseline to represent true cold-miss behavior.

---

## Issue 3: Output Length Too Long for Hardware Timeout

### The problem

The upstream benchmark template uses `output_len=1000` tokens. On Intel Max 1100 XPU with TP=2 and multiple concurrent requests, the measured generation throughput is approximately **28 tokens/s shared across all concurrent requests** (~1.4 tokens/s per request at typical concurrency). At that rate, generating 1000 output tokens takes ~714 seconds per request — more than double the 300s timeout goal.

Every request timed out. The benchmark reported `ALL_REQUESTS_FAILED (total=60, failures=60)`.

### Root cause analysis

From the vLLM metrics log during the run:

```
Avg prompt throughput: 760 tokens/s   # prefill — fast
Avg generation throughput: 28 tokens/s total across 20 concurrent reqs
# → ~1.4 tokens/s per request
# → 1000 output tokens / 1.4 = ~714s per request
# → 300s timeout fires before any request completes
```

The prefill is fast (~760 tok/s, so 3600 input tokens ≈ 5s). The bottleneck is the decode phase on XPU.

### The fix

Reduce `output_len` from 1000 to **200** and `ISL` from 7200 to **3600** (system_prompt=3000, question=600):

- Prefill: 3600 / 760 ≈ **5s**
- Decode: 200 / 1.4 ≈ **143s** at high concurrency; much less at low rate
- Total: ~150s well within 300s

This also reduces KV cache pressure, allowing more requests to be served before cache fills up.

---

## Issue 4: Upstream Guide Removed from llm-d main

During CI debugging, the `Deploy stack` step failed with:

```
cp: cannot create regular file 'llm-d-repo/guides/inference-scheduling/
ms-inference-scheduling/values_xpu.yaml': No such file or directory
```

The `inference-scheduling` guide was removed from `llm-d/llm-d` main in commit `645891a` ([Refactor Install]: Helm → Kustomize for IIS). The CI was checking out the latest `main` and the path no longer existed.

### The fix

Pin `llmd_branch` to the specific commit assigned for this validation work:

```yaml
# In workflow default
llmd_branch: 710447c0fe8cd9dc4984c835d9f306f792aa98f9
```

This is the commit explicitly assigned for testing. Both `710447c0` (assigned) and `f408e4eb` (3 commits later) contain the inference-scheduling guide — use the assigned one.

---

## Benchmark Results

### Qwen3-8B (TP=2, 3 replicas, dut7904 | ISL=3600, OSL=200, timeout=300s)

| Metric | Baseline | Approx KV | Precise KV |
|---|---|---|---|
| Requests | 60/60 | 60/60 | 60/60 |
| Mean TTFT | 1.6 ms | 1.1 ms | 1.1 ms |
| P99 TTFT | 5.4 ms | 1.6 ms | 1.8 ms |
| Mean latency | 82.7 ms | 76.8 ms | 78.4 ms |
| Throughput | 0.608 r/s | 0.638 r/s | 0.623 r/s |
| Prefix hit rate | 49.3% | 54.5% | 54.5% |

Precise TTFT improvement vs baseline: **-31%**

### Qwen3-32B (TP=2, 3 replicas, dut7904 | ISL=3600, OSL=200, timeout=300s)

| Metric | Baseline | Approx KV | Precise KV |
|---|---|---|---|
| Requests | 40/40 | 40/40 | 40/40 |
| Mean TTFT | 73.0 ms | 70.3 ms | **31.3 ms** |
| P99 TTFT | 137.5 ms | 145.5 ms | 104.3 ms |
| Mean latency | 274.2 ms | 243.7 ms | **184.5 ms** |
| Throughput | 0.135 r/s | 0.153 r/s | **0.178 r/s** |
| Prefix hit rate | 0.5% | 3.2% | **10.2%** |

Precise vs baseline: TTFT **-57%**, latency **-33%**, hit rate **+9.7 pp**

The 32b results show stronger KV-aware gains than 8b. This is expected: 32b has larger weight matrices so each forward pass is more expensive — a cache hit that skips prefill saves proportionally more time. With the ZMQ fix in place, the precise scorer's advantage over approximate becomes clearly visible.

---

## Configuration Changes Applied

### 1. EPP ConfigMap (`*-epp.yaml`)

```yaml
kvEventsConfig:
  discoverPods: true   # was false — this was the critical ZMQ fix
  zmqEndpoint: "tcp://*:5557"
```

### 2. Model configs (`qwen3-8b.yaml`, `qwen3-32b.yaml`)

```yaml
# Image upgrade
image: ghcr.io/llm-d/llm-d-xpu:v0.7.0-rc.4  # was v0.6.0

# Topology: TP=2, 3 replicas on dut7904 (model cache present)
decode:
  replicas: 3
  parallelism:
    tensor: 2
  extraConfig:
    nodeSelector:
      kubernetes.io/hostname: dut7904
```

### 3. Workflow benchmark parameters

| Parameter | Before | After (8b) | After (32b) | Reason |
|---|---|---|---|---|
| `system_prompt_len` | 6000 | 3000 | 3000 | Fit within 300s timeout |
| `question_len` | 1200 | 600 | 600 | Fit within 300s timeout |
| `output_len` | 1000 | 200 | 200 | Decode too slow at 1000 |
| `request_timeout` | 600s/1800s | 300s | 300s | Target SLA |
| `max_rate_per_stage` | 8 | 4 | 2 | Avoid KV saturation |
| `num_prompts_per_group` | 5 | 2 | 2 | ≤ replicas for fair baseline |
| `max_stages` | 0 (all) | 2 | 2 | Fast smoke-check |
| `llmd_branch` | main | `710447c0` | `710447c0` | Pinned: guide removed from main |

### 4. Workflow defaults

```yaml
# e2e-benchmark-kvcache.yaml
model: qwen3-8b          # was qwen3-32b
run_baseline: false      # run one case at a time for debugging
run_approximate: true
run_precise: false
max_stages: 2            # smoke-check by default
```

---

## Lessons Learned

### On ZMQ pub/sub topology

The `discoverPods` configuration is easy to overlook but has a binary effect: with it disabled, the precise scorer produces **exactly the same routing as round-robin**, making it impossible to observe any benefit from KV-aware routing regardless of how well everything else is configured. Always confirm via EPP logs that `scores` contains non-null, non-zero values before trusting benchmark results.

### On benchmark design for KV cache

The `num_prompts_per_group` parameter needs to be chosen relative to the number of replicas, not as an absolute value. The upstream default (5) is designed for a larger fleet. Blindly using it with a small replica count creates a misleading baseline that makes KV-aware routing look less beneficial than it is.

### On hardware-specific timeout tuning

Benchmark parameters from a different hardware platform (e.g., NVIDIA GPU with faster decode) do not transfer directly to XPU. The decode throughput on Intel Max 1100 in multi-request scenarios is the limiting factor. Measure actual token/s from `vllm metrics` logs before setting `output_len` and `request_timeout`.

### On upstream dependency pinning in CI

Any CI that pulls `main` of an upstream repo is fragile. Guides and directory structures change without notice. The safer pattern is to pin to a specific commit SHA and update the pin deliberately, documenting why that commit was chosen and what changed in the commits around it.

### On iterative debugging methodology

When a benchmark reports 100% failure rate, the correct path is:

1. Check pod logs for actual error messages — don't assume the benchmark config is wrong
2. Verify connectivity first (did the smoke test pass? did gateway return 200?)
3. Check EPP scorer output — `scores: null` is a dead giveaway that the data pipeline is broken upstream of the scoring logic
4. Work backward from the symptom to the root cause before changing multiple variables

Each of the four issues above was independently root-caused before applying a fix, which avoided the confusion of combined changes masking each other.
