#!/usr/bin/env bash
set -euo pipefail

##################################################################################
# Install NVIDIA Dynamo Platform on a 1-node Kubernetes cluster
#
# What this script does (in order):
#  1) Validates cluster access (kubectl) and Helm availability.
#  2) Installs a default StorageClass (local-path-provisioner) so stateful pods
#     like Dynamo's etcd and nats can get PersistentVolumes on a single node.
#  3) Installs Dynamo CRDs (cluster-scoped) as required by the official guide.
#  4) Installs the Dynamo Platform Helm chart into a chosen namespace.
#  5) Waits and verifies pods + PVCs become ready/bound.
#  5) Installs NVIDIA GPU Operator so Kubernetes advertises nvidia.com/gpu and
#     GPU workloads (like vLLM decode workers) can schedule successfully.
#  6) Checks if nvidia-smi is available on the host; if not, deploys a helper pod.
##################################################################################

# -----------------------------
# User-configurable variables
# -----------------------------

# Namespace where Dynamo platform will be installed
NAMESPACE="${NAMESPACE:-dynamo-system}"

# Dynamo release version. The official guide expects you to set this.
# Example: export RELEASE_VERSION=0.x.y (match NVIDIA Dynamo release you're using)
RELEASE_VERSION="${RELEASE_VERSION:-0.8.1}"

# If you are on a shared/multi-tenant cluster and need namespace restriction, set:
# export NAMESPACE_RESTRICTED_OPERATOR=true
NAMESPACE_RESTRICTED_OPERATOR="${NAMESPACE_RESTRICTED_OPERATOR:-false}"

# Optional multinode components (NOT needed for 1-node cluster; keep false)
ENABLE_GROVE="${ENABLE_GROVE:-false}"
ENABLE_KAI_SCHEDULER="${ENABLE_KAI_SCHEDULER:-false}"

# Prometheus endpoint URL (where Dynamo sends metrics)
# Default: kube-prometheus-stack Prometheus service in monitoring namespace
PROMETHEUS_ENDPOINT="${PROMETHEUS_ENDPOINT:-http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090}"

# Local-path provisioner manifest URL (lightweight dynamic PV provisioning)
LOCAL_PATH_MANIFEST_URL="${LOCAL_PATH_MANIFEST_URL:-https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml}"

# -----------------------------
# GPU Operator configuration
# -----------------------------

# Namespace where GPU Operator will be installed
GPU_OPERATOR_NS="${GPU_OPERATOR_NS:-gpu-operator}"

# Helm release name for GPU Operator
GPU_OPERATOR_RELEASE="${GPU_OPERATOR_RELEASE:-gpu-operator}"

# NVIDIA Helm repo (hosts gpu-operator chart)
NVIDIA_HELM_REPO_NAME="${NVIDIA_HELM_REPO_NAME:-nvidia}"
NVIDIA_HELM_REPO_URL="${NVIDIA_HELM_REPO_URL:-https://helm.ngc.nvidia.com/nvidia}"

# Helm wait timeout for GPU Operator install/upgrade
GPU_OPERATOR_HELM_TIMEOUT="${GPU_OPERATOR_HELM_TIMEOUT:-15m}"

# Wait tuning for nvidia.com/gpu to appear in node allocatable
GPU_ALLOCATABLE_WAIT_ATTEMPTS="${GPU_ALLOCATABLE_WAIT_ATTEMPTS:-120}"
GPU_ALLOCATABLE_WAIT_INTERVAL="${GPU_ALLOCATABLE_WAIT_INTERVAL:-5}"

# -----------------------------
# Helpers
# -----------------------------

log() { echo -e "\n==> $*\n"; }

need_cmd() {
  # Validate required commands exist before doing any work.
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $1" >&2
    exit 1
  fi
}

kube_wait_rollout() {
  # Wait for a deployment to become available
  local ns="$1"
  local deploy="$2"
  kubectl -n "$ns" rollout status "deploy/$deploy" --timeout=300s
}

# -----------------------------
# 0) Pre-flight checks
# -----------------------------

log "Pre-flight: verify kubectl + helm are available"
need_cmd kubectl
need_cmd helm

log "Pre-flight: verify kubectl can talk to the cluster"
# Why: fail early if kubeconfig is wrong or the cluster is down.
kubectl version --client >/dev/null
kubectl get nodes >/dev/null

if [[ -z "${RELEASE_VERSION}" ]]; then
  cat >&2 <<'EOF'
ERROR: RELEASE_VERSION is not set.

The official Dynamo installation guide uses:
  helm fetch ... dynamo-crds-${RELEASE_VERSION}.tgz
  helm fetch ... dynamo-platform-${RELEASE_VERSION}.tgz

Set it like:
  export RELEASE_VERSION=0.x.y

Then re-run the script.
EOF
  exit 1
fi

log "Using configuration:"
echo "  NAMESPACE=${NAMESPACE}"
echo "  RELEASE_VERSION=${RELEASE_VERSION}"
echo "  NAMESPACE_RESTRICTED_OPERATOR=${NAMESPACE_RESTRICTED_OPERATOR}"
echo "  ENABLE_GROVE=${ENABLE_GROVE}"
echo "  ENABLE_KAI_SCHEDULER=${ENABLE_KAI_SCHEDULER}"
echo "  PROMETHEUS_ENDPOINT=${PROMETHEUS_ENDPOINT}"
echo "  GPU_OPERATOR_NS=${GPU_OPERATOR_NS}"
echo "  GPU_OPERATOR_RELEASE=${GPU_OPERATOR_RELEASE}"
echo "  GPU_OPERATOR_HELM_TIMEOUT=${GPU_OPERATOR_HELM_TIMEOUT}"
echo "  GPU_ALLOCATABLE_WAIT_ATTEMPTS=${GPU_ALLOCATABLE_WAIT_ATTEMPTS}"
echo "  GPU_ALLOCATABLE_WAIT_INTERVAL=${GPU_ALLOCATABLE_WAIT_INTERVAL}"

# -----------------------------
# 1) Ensure default StorageClass exists (1-node correction)
# -----------------------------

log "Step 1: Ensure a default StorageClass exists (required so Dynamo etcd/nats PVCs can bind)"
# Why: Dynamo deploys stateful pods that request PersistentVolumes.
#      Many 1-node kubeadm clusters have no dynamic provisioner by default.

if ! kubectl get storageclass >/dev/null 2>&1; then
  # Not expected to fail normally, but keep a clear message.
  echo "ERROR: Unable to list StorageClasses. Check cluster RBAC." >&2
  exit 1
fi

DEFAULT_SC="$(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
  | awk '$2=="true"{print $1; exit}')"

if [[ -n "${DEFAULT_SC}" ]]; then
  echo "A default StorageClass already exists: ${DEFAULT_SC}"
else
  echo "No default StorageClass found. Installing local-path-provisioner for single-node dynamic PVs..."

  # Install local-path provisioner
  # Why: provides dynamic PersistentVolumes backed by local disk on the node.
  kubectl apply -f "${LOCAL_PATH_MANIFEST_URL}"

  # Wait for local-path provisioner to be ready
  # Why: ensures the provisioner can satisfy PVCs before installing Dynamo.
  kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=300s

  # Mark local-path as default StorageClass
  # Why: PVCs that omit storageClassName will use the default class automatically.
  kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

  echo "Default StorageClass set to: local-path"
fi

log "StorageClasses:"
kubectl get storageclass

# -----------------------------
# 2) Install Dynamo CRDs (official step)
# -----------------------------

log "Step 2: Install Dynamo CRDs (cluster-scoped; per official guide)"
# Why: CRDs define Dynamo custom resources that the operator watches/manages.

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

pushd "${WORKDIR}" >/dev/null

helm fetch "https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-crds-${RELEASE_VERSION}.tgz"

# Use upgrade --install so the script can be re-run safely.
helm upgrade --install dynamo-crds "dynamo-crds-${RELEASE_VERSION}.tgz" --namespace default

popd >/dev/null

# -----------------------------
# 3) Install Dynamo Platform (official step)
# -----------------------------

log "Step 3: Install Dynamo Platform (per official guide) into namespace: ${NAMESPACE}"
# Why: This installs the operator and core platform services (including etcd and nats).

pushd "${WORKDIR}" >/dev/null

helm fetch "https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-${RELEASE_VERSION}.tgz"

# Build Helm flags based on options.
HELM_FLAGS=(--namespace "${NAMESPACE}" --create-namespace)

if [[ "${NAMESPACE_RESTRICTED_OPERATOR}" == "true" ]]; then
  HELM_FLAGS+=(--set "dynamo-operator.namespaceRestriction.enabled=true")
fi

if [[ "${ENABLE_GROVE}" == "true" ]]; then
  HELM_FLAGS+=(--set "grove.enabled=true")
fi
if [[ "${ENABLE_KAI_SCHEDULER}" == "true" ]]; then
  HELM_FLAGS+=(--set "kai-scheduler.enabled=true")
fi

# Configure Prometheus endpoint (where Dynamo sends metrics)
if [[ -n "${PROMETHEUS_ENDPOINT}" ]]; then
  HELM_FLAGS+=(--set "prometheusEndpoint=${PROMETHEUS_ENDPOINT}")
  echo "Prometheus endpoint configured: ${PROMETHEUS_ENDPOINT}"
fi

helm upgrade --install dynamo-platform "dynamo-platform-${RELEASE_VERSION}.tgz" "${HELM_FLAGS[@]}"

popd >/dev/null

# -----------------------------
# 4) Wait for readiness and show useful diagnostics
# -----------------------------

log "Step 4: Verify pods and PVCs (this confirms the 1-node storage correction worked)"
# Why: If PVCs don't bind, etcd/nats will stay Pending and Dynamo won't function.

echo "Current pods in ${NAMESPACE}:"
kubectl get pods -n "${NAMESPACE}" -o wide || true

echo
echo "Current PVCs in ${NAMESPACE}:"
kubectl get pvc -n "${NAMESPACE}" || true

log "Waiting for etcd StatefulSet pod to be Ready..."
kubectl wait -n "${NAMESPACE}" --for=condition=Ready pod/dynamo-platform-etcd-0 --timeout=600s

log "Waiting for nats StatefulSet pod to be Ready..."
kubectl wait -n "${NAMESPACE}" --for=condition=Ready pod/dynamo-platform-nats-0 --timeout=600s

log "Waiting for operator controller manager deployment to be Available..."
kubectl -n "${NAMESPACE}" wait --for=condition=Available deploy/dynamo-platform-dynamo-operator-controller-manager --timeout=600s

log "Final status:"
kubectl get pods -n "${NAMESPACE}" -o wide
kubectl get pvc -n "${NAMESPACE}" || true

log "Dynamo platform installed for 1-node cluster ✅"

if [[ -n "${PROMETHEUS_ENDPOINT}" ]]; then
  echo ""
  echo "Prometheus endpoint configured:"
  echo "  - Dynamo will send metrics to: ${PROMETHEUS_ENDPOINT}"
  echo "  - Ensure Prometheus is installed and accessible at this endpoint"
  echo "  - If using kube-prometheus-stack, the default endpoint is:"
  echo "    http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
fi

# -----------------------------
# 5) Install NVIDIA GPU Operator (so GPU workloads can schedule)
# -----------------------------

log "Step 5: Install NVIDIA GPU Operator (enables nvidia.com/gpu in Kubernetes)"
# Why:
# - Your node has GPUs (nvidia-smi works), but Kubernetes only schedules GPU pods
#   once the NVIDIA device plugin is running and advertising nvidia.com/gpu.
# - GPU Operator installs the device plugin + container toolkit integration and
#   keeps them healthy over time.

log "Adding/updating NVIDIA Helm repo (GPU Operator chart source)"
helm repo add "${NVIDIA_HELM_REPO_NAME}" "${NVIDIA_HELM_REPO_URL}" >/dev/null 2>&1 || true
helm repo update >/dev/null

log "Creating GPU Operator namespace (keeps GPU components isolated)"
kubectl create namespace "${GPU_OPERATOR_NS}" >/dev/null 2>&1 || true

log "Installing/upgrading GPU Operator (containerd runtime, with --wait)"
# Note: operator.defaultRuntime=containerd matches your kubeadm/containerd setup.
helm upgrade --install "${GPU_OPERATOR_RELEASE}" "${NVIDIA_HELM_REPO_NAME}/gpu-operator" \
  -n "${GPU_OPERATOR_NS}" \
  --set operator.defaultRuntime=containerd \
  --wait \
  --timeout "${GPU_OPERATOR_HELM_TIMEOUT}"

log "Waiting for GPU Operator pods to be Running/Completed"
# Why: device plugin + toolkit DaemonSets must be ready before GPUs appear on nodes.
for i in {1..180}; do
  NOT_READY="$(kubectl get pods -n "${GPU_OPERATOR_NS}" --no-headers 2>/dev/null \
    | awk '$3!="Running" && $3!="Completed" {print}' | wc -l | tr -d ' ')"
  if [[ "${NOT_READY}" == "0" ]]; then
    break
  fi
  sleep 5
done

kubectl get pods -n "${GPU_OPERATOR_NS}"

log "Verifying GPUs are visible to Kubernetes (nvidia.com/gpu allocatable)"
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable.nvidia\\.com/gpu

# It can take a while after pods are Running/Completed for node allocatable to update.
log "Waiting for nvidia.com/gpu to appear in node allocatable"
GPU_COUNT=""
for ((i=1; i<=GPU_ALLOCATABLE_WAIT_ATTEMPTS; i++)); do
  GPU_COUNT="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "")"
  if [[ -n "${GPU_COUNT}" && "${GPU_COUNT}" != "0" ]]; then
    break
  fi
  sleep "${GPU_ALLOCATABLE_WAIT_INTERVAL}"
done

if [[ -z "${GPU_COUNT}" || "${GPU_COUNT}" == "0" ]]; then
  echo "ERROR: Kubernetes still shows 0 GPUs allocatable. GPU Operator may not be fully ready." >&2
  echo "Debug:" >&2
  echo "  kubectl get pods -n ${GPU_OPERATOR_NS}" >&2
  echo "  kubectl -n ${GPU_OPERATOR_NS} get events --sort-by=.lastTimestamp | tail -n 50" >&2
  exit 1
fi

log "GPU Operator is installed and GPUs are available to schedule ✅"

# -----------------------------
# 6) Ensure nvidia-smi access (host check + helper pod)
# -----------------------------

# log "step 6: verify nvidia-smi is available on the host (or create a helper pod)"

# if ! command -v nvidia-smi >/dev/null 2>&1; then
#   echo "nvidia-smi not found on host. Creating helper pod in ${NAMESPACE}..."

#   kubectl create namespace "${NAMESPACE}" >/dev/null 2>&1 || true

#   if ! kubectl get runtimeclass nvidia >/dev/null 2>&1; then
#     echo "WARNING: RuntimeClass \"nvidia\" not found. Skipping helper pod creation."
#     echo "Hint: ensure the NVIDIA GPU Operator finished successfully, then re-run."
#     echo "Proceeding without nvidia-smi helper."
#   else
#     cat <<YAML | kubectl apply -f -
# apiVersion: v1
# kind: Pod
# metadata:
#   name: nvidia-smi-host
#   namespace: ${NAMESPACE}
# spec:
#   restartPolicy: Never
#   runtimeClassName: nvidia
#   hostPID: true
#   containers:
#   - name: smi
#     image: nvidia/cuda:12.3.2-base-ubuntu22.04
#     securityContext:
#       privileged: true
#     command: ["bash","-lc","nvidia-smi -L && nvidia-smi"]
#     volumeMounts:
#     - name: dev
#       mountPath: /dev
#   volumes:
#   - name: dev
#     hostPath:
#       path: /dev
# YAML

#     log "Reading nvidia-smi output from helper pod logs"
#     kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod/nvidia-smi-host --timeout=10s || true
#     kubectl -n "${NAMESPACE}" wait --for=condition=Succeeded pod/nvidia-smi-host --timeout=10s || true
#     kubectl logs -n "${NAMESPACE}" nvidia-smi-host
#   fi
# else
#   echo "nvidia-smi found on host. Skipping helper pod and alias."
# fi

echo "Next: Deploy a Dynamo GPU workload (e.g., vLLM decode worker) and ensure nvcr.io image pull works."
