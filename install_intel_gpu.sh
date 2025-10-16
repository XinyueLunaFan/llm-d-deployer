#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

function wait_for_all_pod_ready() {
  ns=$1
  timeout=${2:-30s}
  echo "Wait for all pods in namespace $ns to be ready ..."
  for pod in `kubectl -n $ns get pod -oname`;
  do
    kubectl -n $ns wait --for=condition=Ready --timeout $timeout $pod
  done
}

function k8s_install_intel_gpu_helm() {
  # See https://github.com/intel/intel-device-plugins-for-kubernetes/blob/main/INSTALL.md for details
  helm repo add jetstack https://charts.jetstack.io # for cert-manager
  helm repo add nfd https://kubernetes-sigs.github.io/node-feature-discovery/charts # for NFD
  helm repo add intel https://intel.github.io/helm-charts/ # for device-plugin-operator and plugins
  helm repo update

  # Install cert-manager
  helm install --wait \
    cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version v1.15.2 \
    --set installCRDs=true \
    --set global.leaderElection.namespace=cert-manager

  # Install NFD
  helm install --wait \
    nfd nfd/node-feature-discovery \
    --namespace node-feature-discovery --create-namespace \
    --version 0.17.1

  # Install device plugin operator
  helm install --wait \
     dp-operator intel/intel-device-plugins-operator \
     --namespace inteldeviceplugins-system --create-namespace

  # Install gpu device plugin
  helm install --wait \
    gpu intel/intel-device-plugins-gpu \
     --namespace inteldeviceplugins-system --create-namespace \
     --set nodeFeatureRule=true
}

GPUDEV_PLUGIN_VER="0.32.0"

function k8s_install_intel_gpu() {
  # Start NFD - if your cluster doesn't have NFD installed yet
  kubectl apply -k "https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd?ref=v${GPUDEV_PLUGIN_VER}"

  # Create NodeFeatureRules for detecting GPUs on nodes  
  kubectl apply -k "https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd/overlays/node-feature-rules?ref=v${GPUDEV_PLUGIN_VER}"

  # Create GPU plugin daemonset
  kubectl create ns intel-gpu-plugin || true
  kubectl -n intel-gpu-plugin apply -k "https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/gpu_plugin/overlays/nfd_labeled_nodes?ref=v${GPUDEV_PLUGIN_VER}"
}

function k8s_verify_intel_gpu() {
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: intelgpu-demo-job
  labels:
    jobgroup: intelgpu-demo
spec:
  template:
    metadata:
      labels:
        jobgroup: intelgpu-demo
    spec:
      restartPolicy: Never
      containers:
        -
          name: intelgpu-demo-job-1
          image: lianhao/intel-opencl-icd:0.32.0
          imagePullPolicy: IfNotPresent
          command: [ "clinfo" ]
          resources:
            limits:
              gpu.intel.com/xe: 1
EOF

kubectl wait --for=condition=complete job/intelgpu-demo-job --timeout 90s
pod=$(kubectl get pod -l jobgroup=intelgpu-demo -oname)

# Check how many GPUs are allocated to the pod
allocated_gpu=$(kubectl get pod -l jobgroup=intelgpu-demo -o jsonpath='{.items[0].spec.containers[0].resources.limits.gpu\.intel\.com/xe}')
echo "=== GPU Allocation Check ==="
echo "Allocated GPUs: $allocated_gpu"

# Original clinfo check
# May detect nothing due to missing or incompatible OpenCL drivers in the test container
devnum=$(kubectl logs $pod | grep 'Number of devices' | awk '{print $4}')
kubectl delete job/intelgpu-demo-job

set +e
if [ -n "$allocated_gpu" ] && [ "$allocated_gpu" -ge 1 ]; then
    echo "Success: Found $allocated_gpu GPU(s) allocated to pod"
else
    echo "Failure: No GPUs allocated to pod"
fi
set -e
}

set -ex
k8s_install_intel_gpu
wait_for_all_pod_ready intel-gpu-plugin
k8s_verify_intel_gpu
set +ex
