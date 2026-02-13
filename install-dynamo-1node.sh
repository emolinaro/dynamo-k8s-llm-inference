#!/usr/bin/env bash
set -euo pipefail

##################################################################################
# Install NVIDIA Dynamo Platform on a 1-node Kubernetes cluster
#
# What this script does (in order):
#  1) Validates cluster access (kubectl) and Helm availability.
#  2) Installs a default StorageClass (local-path-provisioner) for single-node
#     clusters that need PVCs (optional but recommended).
#  3) Installs Dynamo CRDs (cluster-scoped) as required by the official guide.
#  4) Installs the Dynamo Platform Helm chart into a chosen namespace.
#  5) Waits and verifies pods + PVCs become ready/bound.
#  6) Installs NVIDIA GPU Operator so Kubernetes advertises nvidia.com/gpu and
#     GPU workloads (like vLLM decode workers) can schedule successfully.
#  7) Checks if nvidia-smi is available on the host; if not, deploys a helper pod.
##################################################################################

# -----------------------------
# User-configurable variables
# -----------------------------

# Namespace where Dynamo platform will be installed
NAMESPACE="${NAMESPACE:-dynamo-system}"

# Dynamo release version you intend to deploy against.
# Keep this aligned with your manifests/runtime images.
RELEASE_VERSION="${RELEASE_VERSION:-0.9.0}"

# Helm chart version to install for dynamo-crds and dynamo-platform.
# Defaults to RELEASE_VERSION, but can be pinned independently when chart
# publication lags behind a source-code release tag.
CHART_VERSION="${CHART_VERSION:-${RELEASE_VERSION}}"

# If you are on a shared/multi-tenant cluster and need namespace restriction, set:
# export NAMESPACE_RESTRICTED_OPERATOR=true
NAMESPACE_RESTRICTED_OPERATOR="${NAMESPACE_RESTRICTED_OPERATOR:-false}"

# Skip CRD installation (useful for shared clusters with existing CRDs)
SKIP_CRDS="${SKIP_CRDS:-false}"

# Control bundled etcd/nats subcharts in dynamo-platform.
# Values: auto|true|false
# - auto: disable for RELEASE_VERSION >= 0.9, enable otherwise
# - true: always disable bundled etcd/nats
# - false: always keep bundled etcd/nats enabled
DISABLE_ETCD_NATS="${DISABLE_ETCD_NATS:-auto}"

# Helm chart transport mode:
# - auto: try OCI first, fall back to legacy https fetch
# - oci: force OCI registry (oci://helm.ngc.nvidia.com/...)
# - http: force legacy https fetch (https://helm.ngc.nvidia.com/...)
HELM_CHART_MODE="${HELM_CHART_MODE:-auto}"

# Optional multinode components (NOT needed for 1-node cluster; keep false)
ENABLE_GROVE="${ENABLE_GROVE:-false}"
ENABLE_KAI_SCHEDULER="${ENABLE_KAI_SCHEDULER:-false}"

# Prometheus endpoint URL (where Dynamo sends metrics)
# Default: kube-prometheus-stack Prometheus service in monitoring namespace
PROMETHEUS_ENDPOINT="${PROMETHEUS_ENDPOINT:-http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090}"

# Timeout for operator + webhook readiness check
OPERATOR_WEBHOOK_TIMEOUT="${OPERATOR_WEBHOOK_TIMEOUT:-600}"

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

helm_install_chart() {
  local release="$1"
  local chart="$2"
  local namespace="$3"
  shift 3
  local extra_args=("$@")

  local oci_chart="oci://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/${chart}"
  local http_chart="https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/${chart}-${CHART_VERSION}.tgz"
  local oci_err_file
  local http_err_file
  oci_err_file="$(mktemp)"
  http_err_file="$(mktemp)"

  case "${HELM_CHART_MODE}" in
    oci)
      if ! helm upgrade --install "${release}" "${oci_chart}" --version "${CHART_VERSION}" \
        --namespace "${namespace}" "${extra_args[@]}" 2> >(tee "${oci_err_file}" >&2); then
        if grep -Eqi '400: Bad Request|404|manifest unknown|not found|FetchReference' "${oci_err_file}"; then
          echo "ERROR: Dynamo chart '${chart}' version '${CHART_VERSION}' was not found in NGC OCI registry." >&2
          echo "Try a published chart version, for example:" >&2
          echo "  CHART_VERSION=<published-chart-version> RELEASE_VERSION=${RELEASE_VERSION} ./install-dynamo-1node.sh" >&2
        fi
        rm -f "${oci_err_file}" "${http_err_file}"
        return 1
      fi
      rm -f "${oci_err_file}" "${http_err_file}"
      ;;
    http)
      if ! helm fetch "${http_chart}" 2> >(tee "${http_err_file}" >&2); then
        if grep -Eqi '404|not found' "${http_err_file}"; then
          echo "ERROR: Dynamo chart '${chart}' version '${CHART_VERSION}' was not found in NGC HTTP repo." >&2
          echo "Try a published chart version, for example:" >&2
          echo "  CHART_VERSION=<published-chart-version> RELEASE_VERSION=${RELEASE_VERSION} ./install-dynamo-1node.sh" >&2
        fi
        rm -f "${oci_err_file}" "${http_err_file}"
        return 1
      fi
      helm upgrade --install "${release}" "${chart}-${CHART_VERSION}.tgz" \
        --namespace "${namespace}" "${extra_args[@]}"
      rm -f "${oci_err_file}" "${http_err_file}"
      ;;
    auto)
      if helm upgrade --install "${release}" "${oci_chart}" --version "${CHART_VERSION}" \
        --namespace "${namespace}" "${extra_args[@]}" 2> >(tee "${oci_err_file}" >&2); then
        rm -f "${oci_err_file}" "${http_err_file}"
        return 0
      fi
      echo "WARN: OCI install failed for ${chart}. Falling back to legacy https fetch..." >&2
      if ! helm fetch "${http_chart}" 2> >(tee "${http_err_file}" >&2); then
        if grep -Eqi '400: Bad Request|404|manifest unknown|not found|FetchReference' "${oci_err_file}" || \
           grep -Eqi '404|not found' "${http_err_file}"; then
          echo "ERROR: Dynamo chart '${chart}' version '${CHART_VERSION}' is not published in NGC (OCI/HTTP)." >&2
          echo "To continue, set CHART_VERSION to an available chart version, for example:" >&2
          echo "  CHART_VERSION=<published-chart-version> RELEASE_VERSION=${RELEASE_VERSION} ./install-dynamo-1node.sh" >&2
          echo "You can list versions with:" >&2
          echo "  helm repo add ai-dynamo https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts" >&2
          echo "  helm repo update && helm search repo ai-dynamo/${chart} --versions | head" >&2
        fi
        rm -f "${oci_err_file}" "${http_err_file}"
        return 1
      fi
      helm upgrade --install "${release}" "${chart}-${CHART_VERSION}.tgz" \
        --namespace "${namespace}" "${extra_args[@]}"
      rm -f "${oci_err_file}" "${http_err_file}"
      ;;
    *)
      echo "ERROR: HELM_CHART_MODE must be one of: auto|oci|http" >&2
      exit 1
      ;;
  esac
}

release_ge_0_9() {
  local ver major minor
  ver="${RELEASE_VERSION#v}"
  major="$(printf '%s' "${ver}" | cut -d. -f1 | sed 's/[^0-9].*$//')"
  minor="$(printf '%s' "${ver}" | cut -d. -f2 | sed 's/[^0-9].*$//')"

  if [[ ! "${major}" =~ ^[0-9]+$ || ! "${minor}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  (( major > 0 || (major == 0 && minor >= 9) ))
}

should_disable_etcd_nats() {
  case "${DISABLE_ETCD_NATS}" in
    true) return 0 ;;
    false) return 1 ;;
    auto)
      if release_ge_0_9; then
        return 0
      fi
      return 1
      ;;
    *)
      echo "ERROR: DISABLE_ETCD_NATS must be one of: auto|true|false" >&2
      exit 1
      ;;
  esac
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

remove_operator_enable_webhooks_flag_if_present() {
  local namespace="$1"
  local deploy_name="dynamo-platform-dynamo-operator-controller-manager"
  local target_index="0"
  local args_raw
  local filtered=()
  local changed="false"
  local args_json="["
  local arg

  # Helm can return before the deployment object is fully visible.
  for _ in {1..30}; do
    if kubectl -n "${namespace}" get deploy "${deploy_name}" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if ! kubectl -n "${namespace}" get deploy "${deploy_name}" >/dev/null 2>&1; then
    return 0
  fi

  target_index="$(kubectl -n "${namespace}" get deploy "${deploy_name}" \
    -o go-template='{{range $i, $c := .spec.template.spec.containers}}{{if eq $c.name "manager"}}{{$i}}{{end}}{{end}}' 2>/dev/null || true)"
  if [[ -z "${target_index}" ]]; then
    target_index="0"
  fi

  args_raw="$(kubectl -n "${namespace}" get deploy "${deploy_name}" \
    -o go-template="{{range (index .spec.template.spec.containers ${target_index}).args}}{{println .}}{{end}}" 2>/dev/null || true)"

  if [[ -z "${args_raw}" ]]; then
    return 0
  fi

  while IFS= read -r arg; do
    [[ -z "${arg}" ]] && continue
    if [[ "${arg}" =~ ^--?enable-webhooks($|=) ]]; then
      changed="true"
      continue
    fi
    filtered+=("${arg}")
  done <<< "${args_raw}"

  if [[ "${changed}" != "true" ]]; then
    return 0
  fi

  for arg in "${filtered[@]}"; do
    args_json+="\"$(json_escape "${arg}")\","
  done
  args_json="${args_json%,}]"

  log "Detected unsupported operator flag '-enable-webhooks'; patching deployment args"
  kubectl -n "${namespace}" patch deploy "${deploy_name}" --type='json' \
    -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/${target_index}/args\",\"value\":${args_json}}]"
}

kube_wait_rollout() {
  # Wait for a deployment to become available
  local ns="$1"
  local deploy="$2"
  kubectl -n "$ns" rollout status "deploy/$deploy" --timeout=300s
}

wait_for_service_endpoints() {
  local ns="$1"
  local svc="$2"
  local timeout="$3"
  local start
  start="$(date +%s)"

  while true; do
    if kubectl -n "${ns}" get endpoints "${svc}" -o jsonpath='{.subsets[0].addresses[0].ip}' >/dev/null 2>&1; then
      return 0
    fi

    if (( "$(date +%s)" - start > timeout )); then
      return 1
    fi
    sleep 5
  done
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

Set it like:
  export RELEASE_VERSION=0.x.y

Then re-run the script.
EOF
  exit 1
fi

log "Using configuration:"
echo "  NAMESPACE=${NAMESPACE}"
echo "  RELEASE_VERSION=${RELEASE_VERSION}"
echo "  CHART_VERSION=${CHART_VERSION}"
echo "  NAMESPACE_RESTRICTED_OPERATOR=${NAMESPACE_RESTRICTED_OPERATOR}"
echo "  SKIP_CRDS=${SKIP_CRDS}"
echo "  DISABLE_ETCD_NATS=${DISABLE_ETCD_NATS}"
echo "  HELM_CHART_MODE=${HELM_CHART_MODE}"
echo "  ENABLE_GROVE=${ENABLE_GROVE}"
echo "  ENABLE_KAI_SCHEDULER=${ENABLE_KAI_SCHEDULER}"
echo "  PROMETHEUS_ENDPOINT=${PROMETHEUS_ENDPOINT}"
echo "  OPERATOR_WEBHOOK_TIMEOUT=${OPERATOR_WEBHOOK_TIMEOUT}"
echo "  GPU_OPERATOR_NS=${GPU_OPERATOR_NS}"
echo "  GPU_OPERATOR_RELEASE=${GPU_OPERATOR_RELEASE}"
echo "  GPU_OPERATOR_HELM_TIMEOUT=${GPU_OPERATOR_HELM_TIMEOUT}"
echo "  GPU_ALLOCATABLE_WAIT_ATTEMPTS=${GPU_ALLOCATABLE_WAIT_ATTEMPTS}"
echo "  GPU_ALLOCATABLE_WAIT_INTERVAL=${GPU_ALLOCATABLE_WAIT_INTERVAL}"

if [[ "${CHART_VERSION}" != "${RELEASE_VERSION}" ]]; then
  echo "NOTE: CHART_VERSION (${CHART_VERSION}) differs from RELEASE_VERSION (${RELEASE_VERSION})."
fi

# -----------------------------
# 1) Ensure default StorageClass exists (1-node correction)
# -----------------------------

log "Step 1: Ensure a default StorageClass exists (recommended for PVCs on 1-node clusters)"
# Why: Some Dynamo components or workloads may request PersistentVolumes.
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

if [[ "${SKIP_CRDS}" == "true" ]]; then
  echo "SKIP_CRDS=true -> skipping CRD installation."
else
  if kubectl get crd -o name | grep -qi "dynamo"; then
    echo "Detected existing Dynamo CRDs."
    echo "If this is a shared cluster, set SKIP_CRDS=true to skip reinstalling CRDs."
  fi

  pushd "${WORKDIR}" >/dev/null

  # Use upgrade --install so the script can be re-run safely.
  helm_install_chart "dynamo-crds" "dynamo-crds" "default"

  popd >/dev/null
fi

# -----------------------------
# 3) Install Dynamo Platform (official step)
# -----------------------------

log "Step 3: Install Dynamo Platform (per official guide) into namespace: ${NAMESPACE}"
# Why: This installs the operator and core platform services.

pushd "${WORKDIR}" >/dev/null

# Build Helm flags based on options.
HELM_FLAGS=(--create-namespace)

# Keep webhook explicitly enabled (defensive). We rely on admission webhooks for
# early validation and deploy-incluster depends on this endpoint.
HELM_FLAGS+=(--set "dynamo-operator.webhook.enabled=true")

if [[ "${NAMESPACE_RESTRICTED_OPERATOR}" == "true" ]]; then
  HELM_FLAGS+=(--set "dynamo-operator.namespaceRestriction.enabled=true")
fi

if [[ "${ENABLE_GROVE}" == "true" ]]; then
  HELM_FLAGS+=(--set "grove.enabled=true")
fi
if [[ "${ENABLE_KAI_SCHEDULER}" == "true" ]]; then
  HELM_FLAGS+=(--set "kai-scheduler.enabled=true")
fi

if should_disable_etcd_nats; then
  HELM_FLAGS+=(--set "nats.enabled=false")
  HELM_FLAGS+=(--set "etcd.enabled=false")
  echo "Bundled nats/etcd disabled (DISABLE_ETCD_NATS=${DISABLE_ETCD_NATS}, RELEASE_VERSION=${RELEASE_VERSION})"
fi

# Configure Prometheus endpoint (where Dynamo sends metrics)
if [[ -n "${PROMETHEUS_ENDPOINT}" ]]; then
  HELM_FLAGS+=(--set "prometheusEndpoint=${PROMETHEUS_ENDPOINT}")
  echo "Prometheus endpoint configured: ${PROMETHEUS_ENDPOINT}"
fi

helm_install_chart "dynamo-platform" "dynamo-platform" "${NAMESPACE}" "${HELM_FLAGS[@]}"
remove_operator_enable_webhooks_flag_if_present "${NAMESPACE}"

log "Step 3a: Verify Dynamo operator webhook endpoint is ready"
kubectl -n "${NAMESPACE}" rollout status deploy/dynamo-platform-dynamo-operator-controller-manager \
  --timeout="${OPERATOR_WEBHOOK_TIMEOUT}s"
if ! wait_for_service_endpoints "${NAMESPACE}" "dynamo-platform-dynamo-operator-webhook-service" "${OPERATOR_WEBHOOK_TIMEOUT}"; then
  echo "ERROR: Dynamo webhook service has no ready endpoints after install." >&2
  echo "Debug:" >&2
  echo "  kubectl -n ${NAMESPACE} get pods -o wide | grep -E 'dynamo-operator|controller-manager'" >&2
  echo "  kubectl -n ${NAMESPACE} get svc dynamo-platform-dynamo-operator-webhook-service -o yaml" >&2
  echo "  kubectl -n ${NAMESPACE} get endpoints dynamo-platform-dynamo-operator-webhook-service -o yaml" >&2
  echo "  kubectl -n ${NAMESPACE} logs deploy/dynamo-platform-dynamo-operator-controller-manager -c manager --tail=200" >&2
  exit 1
fi

popd >/dev/null

# -----------------------------
# 4) Wait for readiness and show useful diagnostics
# -----------------------------

log "Step 4: Verify pods and PVCs"
# Why: If PVCs don't bind, stateful components may stay Pending.

echo "Current pods in ${NAMESPACE}:"
kubectl get pods -n "${NAMESPACE}" -o wide || true

echo
echo "Current PVCs in ${NAMESPACE}:"
kubectl get pvc -n "${NAMESPACE}" || true

log "Waiting for platform deployments to become Available..."
DEPLOYS="$(kubectl -n "${NAMESPACE}" get deploy -o name 2>/dev/null || true)"
if [[ -n "${DEPLOYS}" ]]; then
  while read -r deploy; do
    [[ -z "${deploy}" ]] && continue
    kubectl -n "${NAMESPACE}" rollout status "${deploy}" --timeout=600s
  done <<< "${DEPLOYS}"
else
  echo "No deployments found in namespace ${NAMESPACE} yet."
fi

log "Waiting for platform StatefulSets to become Ready..."
STATEFULSETS="$(kubectl -n "${NAMESPACE}" get sts -o name 2>/dev/null || true)"
if [[ -n "${STATEFULSETS}" ]]; then
  while read -r sts; do
    [[ -z "${sts}" ]] && continue
    kubectl -n "${NAMESPACE}" rollout status "${sts}" --timeout=600s
  done <<< "${STATEFULSETS}"
else
  echo "No StatefulSets found in namespace ${NAMESPACE}."
fi

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

echo "Next: Deploy a Dynamo GPU workload (e.g., vLLM decode worker) and ensure nvcr.io image pull works."
