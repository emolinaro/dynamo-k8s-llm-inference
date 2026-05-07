#!/usr/bin/env bash
set -euo pipefail

##################################################################################
# Install or upgrade NVIDIA Dynamo Platform on a 1-node Kubernetes cluster.
#
# This script follows the Dynamo 1.x install/upgrade flow:
#  1) Validates cluster access and Helm availability.
#  2) Verifies the storage class used by Dynamo stateful components.
#  3) Pulls the Dynamo Platform Helm chart archive from NGC.
#  4) Applies Dynamo CRDs manually from the chart with server-side apply.
#  5) Installs/upgrades the Dynamo Platform chart with 1.x Helm value keys.
#  6) Waits and verifies pods + PVCs become ready/bound.
#  7) Installs NVIDIA GPU Operator so Kubernetes advertises nvidia.com/gpu.
##################################################################################

# -----------------------------
# User-configurable variables
# -----------------------------

# Namespace where Dynamo platform will be installed.
NAMESPACE="${NAMESPACE:-dynamo-system}"

# Helm release name for Dynamo Platform.
RELEASE_NAME="${RELEASE_NAME:-dynamo-platform}"

# Dynamo release/runtime version you intend to deploy against.
RELEASE_VERSION="${RELEASE_VERSION:-1.1.0}"

# Helm chart version to install. NGC chart versions do not use a leading "v".
CHART_VERSION="${CHART_VERSION:-${RELEASE_VERSION#v}}"
CHART_URL="${CHART_URL:-https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-${CHART_VERSION}.tgz}"

# The 1.x namespace-restricted flow applies CRDs manually, then tells Helm
# not to let the operator pod create/upgrade cluster-scoped CRDs.
NAMESPACE_RESTRICTED_OPERATOR="${NAMESPACE_RESTRICTED_OPERATOR:-true}"
SKIP_CRDS="${SKIP_CRDS:-false}"

# Storage class used by bundled etcd persistence and NATS JetStream.
# Keep the repo's single-node default behavior by using local-path. Set
# DYNAMO_STORAGE_CLASS=csi-rbd-sc to match the referenced install instructions.
DYNAMO_STORAGE_CLASS="${DYNAMO_STORAGE_CLASS:-local-path}"

# Preserve the 1.x topology from INSTALL_INSTRUCTIONS.md.
INSTALL_BUNDLED_ETCD="${INSTALL_BUNDLED_ETCD:-true}"
ENABLE_GROVE="${ENABLE_GROVE:-false}"
ENABLE_KAI_SCHEDULER="${ENABLE_KAI_SCHEDULER:-false}"

# Prometheus endpoint URL where Dynamo sends metrics.
PROMETHEUS_ENDPOINT="${PROMETHEUS_ENDPOINT:-http://prometheus-server.monitoring.svc.cluster.local}"

# Optional Hugging Face token secret. If HF_TOKEN is empty, this step is skipped.
HF_TOKEN="${HF_TOKEN:-}"
HF_TOKEN_SECRET_NAME="${HF_TOKEN_SECRET_NAME:-hf-token-secret}"

# Timeout for platform install and operator webhook readiness checks.
PLATFORM_HELM_TIMEOUT="${PLATFORM_HELM_TIMEOUT:-30m}"
OPERATOR_WEBHOOK_TIMEOUT="${OPERATOR_WEBHOOK_TIMEOUT:-600}"

# Local-path provisioner manifest URL. Used only when DYNAMO_STORAGE_CLASS=local-path
# and the local-path StorageClass is not already installed.
LOCAL_PATH_MANIFEST_URL="${LOCAL_PATH_MANIFEST_URL:-https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml}"

# Resume support. Completed step markers are stored under DYNAMO_INSTALL_STATE_DIR
# so reruns can continue after the last successfully completed step.
RESUME_INSTALL="${RESUME_INSTALL:-true}"
RESET_RESUME_STATE="${RESET_RESUME_STATE:-false}"
DYNAMO_INSTALL_STATE_ROOT="${DYNAMO_INSTALL_STATE_ROOT:-${HOME}/.cache/dynamo-k8s-llm-inference}"
DYNAMO_INSTALL_STATE_DIR="${DYNAMO_INSTALL_STATE_DIR:-}"
DYNAMO_WORKDIR="${DYNAMO_WORKDIR:-}"

# -----------------------------
# GPU Operator configuration
# -----------------------------

INSTALL_GPU_OPERATOR="${INSTALL_GPU_OPERATOR:-true}"
REQUIRE_GPUS="${REQUIRE_GPUS:-true}"
GPU_OPERATOR_NS="${GPU_OPERATOR_NS:-gpu-operator}"
GPU_OPERATOR_RELEASE="${GPU_OPERATOR_RELEASE:-gpu-operator}"
NVIDIA_HELM_REPO_NAME="${NVIDIA_HELM_REPO_NAME:-nvidia}"
NVIDIA_HELM_REPO_URL="${NVIDIA_HELM_REPO_URL:-https://helm.ngc.nvidia.com/nvidia}"
GPU_OPERATOR_HELM_TIMEOUT="${GPU_OPERATOR_HELM_TIMEOUT:-15m}"
GPU_ALLOCATABLE_WAIT_ATTEMPTS="${GPU_ALLOCATABLE_WAIT_ATTEMPTS:-120}"
GPU_ALLOCATABLE_WAIT_INTERVAL="${GPU_ALLOCATABLE_WAIT_INTERVAL:-5}"

# -----------------------------
# Derived values
# -----------------------------

DYNAMO_OPERATOR_DEPLOYMENT="${DYNAMO_OPERATOR_DEPLOYMENT:-${RELEASE_NAME}-dynamo-operator-controller-manager}"
DYNAMO_OPERATOR_WEBHOOK_SERVICE="${DYNAMO_OPERATOR_WEBHOOK_SERVICE:-${RELEASE_NAME}-dynamo-operator-webhook-service}"
DYNAMO_CHART_ARCHIVE=""
DYNAMO_CHART_DIR=""
DYNAMO_CRDS_DIR=""
DYNAMO_STEP_DIR=""

# -----------------------------
# Helpers
# -----------------------------

log() { echo -e "\n==> $*\n"; }

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $1" >&2
    exit 1
  fi
}

validate_bool() {
  local name="$1"
  local value="$2"

  case "${value}" in
    true|false) ;;
    *)
      echo "ERROR: ${name} must be true or false; got '${value}'." >&2
      exit 1
      ;;
  esac
}

resume_fingerprint_input() {
  cat <<EOF
NAMESPACE=${NAMESPACE}
RELEASE_NAME=${RELEASE_NAME}
RELEASE_VERSION=${RELEASE_VERSION}
CHART_VERSION=${CHART_VERSION}
CHART_URL=${CHART_URL}
NAMESPACE_RESTRICTED_OPERATOR=${NAMESPACE_RESTRICTED_OPERATOR}
SKIP_CRDS=${SKIP_CRDS}
DYNAMO_STORAGE_CLASS=${DYNAMO_STORAGE_CLASS}
INSTALL_BUNDLED_ETCD=${INSTALL_BUNDLED_ETCD}
ENABLE_GROVE=${ENABLE_GROVE}
ENABLE_KAI_SCHEDULER=${ENABLE_KAI_SCHEDULER}
PROMETHEUS_ENDPOINT=${PROMETHEUS_ENDPOINT}
HF_TOKEN_SECRET_NAME=${HF_TOKEN_SECRET_NAME}
PLATFORM_HELM_TIMEOUT=${PLATFORM_HELM_TIMEOUT}
OPERATOR_WEBHOOK_TIMEOUT=${OPERATOR_WEBHOOK_TIMEOUT}
INSTALL_GPU_OPERATOR=${INSTALL_GPU_OPERATOR}
REQUIRE_GPUS=${REQUIRE_GPUS}
GPU_OPERATOR_NS=${GPU_OPERATOR_NS}
GPU_OPERATOR_RELEASE=${GPU_OPERATOR_RELEASE}
NVIDIA_HELM_REPO_NAME=${NVIDIA_HELM_REPO_NAME}
NVIDIA_HELM_REPO_URL=${NVIDIA_HELM_REPO_URL}
GPU_OPERATOR_HELM_TIMEOUT=${GPU_OPERATOR_HELM_TIMEOUT}
GPU_ALLOCATABLE_WAIT_ATTEMPTS=${GPU_ALLOCATABLE_WAIT_ATTEMPTS}
GPU_ALLOCATABLE_WAIT_INTERVAL=${GPU_ALLOCATABLE_WAIT_INTERVAL}
EOF
}

configure_resume_state() {
  local fingerprint

  fingerprint="$(resume_fingerprint_input | cksum | awk '{print $1}')"

  if [[ -z "${DYNAMO_INSTALL_STATE_DIR}" ]]; then
    DYNAMO_INSTALL_STATE_DIR="${DYNAMO_INSTALL_STATE_ROOT}/install-dynamo-1node-${fingerprint}"
  fi
  if [[ -z "${DYNAMO_WORKDIR}" ]]; then
    DYNAMO_WORKDIR="${DYNAMO_INSTALL_STATE_DIR}/work"
  fi
  DYNAMO_STEP_DIR="${DYNAMO_INSTALL_STATE_DIR}/steps"

  if [[ "${RESET_RESUME_STATE}" == "true" ]]; then
    echo "RESET_RESUME_STATE=true -> clearing ${DYNAMO_INSTALL_STATE_DIR}"
    rm -rf "${DYNAMO_INSTALL_STATE_DIR}"
  fi

  mkdir -p "${DYNAMO_STEP_DIR}" "${DYNAMO_WORKDIR}"
  resume_fingerprint_input >"${DYNAMO_INSTALL_STATE_DIR}/config.txt"
}

step_marker() {
  local step_name="$1"
  printf '%s/%s.done' "${DYNAMO_STEP_DIR}" "${step_name}"
}

step_done() {
  local step_name="$1"

  [[ "${RESUME_INSTALL}" == "true" && -f "$(step_marker "${step_name}")" ]]
}

mark_step_done() {
  local step_name="$1"

  if [[ "${RESUME_INSTALL}" != "true" ]]; then
    return 0
  fi

  date -u +"%Y-%m-%dT%H:%M:%SZ" >"$(step_marker "${step_name}")"
}

run_step() {
  local step_name="$1"
  shift

  if step_done "${step_name}"; then
    echo "Resume: skipping completed step '${step_name}'."
    return 0
  fi

  "$@"
  mark_step_done "${step_name}"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

storage_class_exists() {
  kubectl get storageclass "$1" >/dev/null 2>&1
}

install_local_path_storage_class() {
  log "Installing local-path-provisioner for single-node dynamic PVs"
  kubectl apply -f "${LOCAL_PATH_MANIFEST_URL}"
  kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=300s
  kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

ensure_dynamo_storage_class() {
  log "Step 1: Verify Dynamo storage class: ${DYNAMO_STORAGE_CLASS}"

  if [[ -z "${DYNAMO_STORAGE_CLASS}" ]]; then
    echo "ERROR: DYNAMO_STORAGE_CLASS cannot be empty." >&2
    exit 1
  fi

  if storage_class_exists "${DYNAMO_STORAGE_CLASS}"; then
    echo "Dynamo storage class exists: ${DYNAMO_STORAGE_CLASS}"
  elif [[ "${DYNAMO_STORAGE_CLASS}" == "local-path" ]]; then
    install_local_path_storage_class
  else
    echo "ERROR: StorageClass '${DYNAMO_STORAGE_CLASS}' does not exist." >&2
    echo "Create it before running this script, or use DYNAMO_STORAGE_CLASS=local-path for a local single-node cluster." >&2
    exit 1
  fi

  echo
  echo "StorageClasses:"
  kubectl get storageclass
}

snapshot_existing_release() {
  if ! helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    return 0
  fi

  log "Snapshot existing ${RELEASE_NAME} release before upgrade"
  helm list -n "${NAMESPACE}" || true
  helm history "${RELEASE_NAME}" -n "${NAMESPACE}" || true
  helm get values "${RELEASE_NAME}" -n "${NAMESPACE}" -o yaml \
    >"/tmp/${RELEASE_NAME}.values.before-${CHART_VERSION}.yaml" || true
  echo "Saved current Helm values to /tmp/${RELEASE_NAME}.values.before-${CHART_VERSION}.yaml"
}

prepare_dynamo_chart() {
  local workdir="$1"
  local expected_archive="${workdir}/dynamo-platform-${CHART_VERSION}.tgz"
  local chart_extract_dir="${workdir}/dynamo-platform-${CHART_VERSION}"
  local candidate

  log "Step 2: Pull Dynamo Platform chart ${CHART_VERSION}"
  mkdir -p "${workdir}"

  if [[ -f "${expected_archive}" ]]; then
    echo "Reusing chart archive: ${expected_archive}"
  else
    helm pull "${CHART_URL}" -d "${workdir}"
  fi

  if [[ -f "${expected_archive}" ]]; then
    DYNAMO_CHART_ARCHIVE="${expected_archive}"
  else
    for candidate in "${workdir}"/dynamo-platform-*.tgz; do
      if [[ -f "${candidate}" ]]; then
        DYNAMO_CHART_ARCHIVE="${candidate}"
        break
      fi
    done
  fi

  if [[ -z "${DYNAMO_CHART_ARCHIVE}" || ! -f "${DYNAMO_CHART_ARCHIVE}" ]]; then
    echo "ERROR: Could not find pulled dynamo-platform chart archive in ${workdir}." >&2
    exit 1
  fi

  helm show chart "${DYNAMO_CHART_ARCHIVE}"

  if [[ -d "${chart_extract_dir}/dynamo-platform" ]]; then
    echo "Reusing extracted chart directory: ${chart_extract_dir}/dynamo-platform"
  else
    mkdir -p "${chart_extract_dir}"
    tar -xf "${DYNAMO_CHART_ARCHIVE}" -C "${chart_extract_dir}"
  fi

  DYNAMO_CHART_DIR="${chart_extract_dir}/dynamo-platform"
  DYNAMO_CRDS_DIR="${DYNAMO_CHART_DIR}/charts/dynamo-operator/crds"

  if [[ ! -d "${DYNAMO_CHART_DIR}" ]]; then
    echo "ERROR: Extracted chart directory not found: ${DYNAMO_CHART_DIR}" >&2
    exit 1
  fi

  if [[ ! -d "${DYNAMO_CRDS_DIR}" ]]; then
    echo "ERROR: Dynamo operator CRD directory not found: ${DYNAMO_CRDS_DIR}" >&2
    exit 1
  fi
}

apply_dynamo_crds() {
  log "Step 3: Apply Dynamo CRDs manually"

  if [[ "${SKIP_CRDS}" == "true" ]]; then
    echo "SKIP_CRDS=true -> skipping CRD installation."
    return 0
  fi

  kubectl apply --server-side --force-conflicts -f "${DYNAMO_CRDS_DIR}/"

  echo
  echo "Dynamo CRDs:"
  if ! kubectl get crd | grep -E 'dynamo(checkpoints|componentdeployments|graphdeploymentrequests|graphdeployments|graphdeploymentscalingadapters|models|workermetadatas)\.nvidia\.com'; then
    echo "WARN: Expected Dynamo CRD names were not found in kubectl output." >&2
  fi
}

create_hf_token_secret_if_requested() {
  if [[ -z "${HF_TOKEN}" ]]; then
    echo "HF_TOKEN is not set; skipping ${HF_TOKEN_SECRET_NAME} creation."
    return 0
  fi

  log "Create or update ${HF_TOKEN_SECRET_NAME}"
  kubectl create namespace "${NAMESPACE}" >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" create secret generic "${HF_TOKEN_SECRET_NAME}" \
    --from-literal=HF_TOKEN="${HF_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

remove_operator_enable_webhooks_flag_if_present() {
  local namespace="$1"
  local deploy_name="${DYNAMO_OPERATOR_DEPLOYMENT}"
  local target_index="0"
  local args_raw
  local filtered=()
  local changed="false"
  local args_json="["
  local arg

  for _ in {1..30}; do
    if kubectl -n "${namespace}" get deploy "${deploy_name}" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if ! kubectl -n "${namespace}" get deploy "${deploy_name}" >/dev/null 2>&1; then
    return 0
  fi

  # shellcheck disable=SC2016
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

install_or_upgrade_dynamo_platform() {
  local -a helm_flags
  helm_flags=(
    --create-namespace
    --skip-crds
    --wait
    --timeout "${PLATFORM_HELM_TIMEOUT}"
    --set "dynamo-operator.upgradeCRD=false"
    --set "dynamo-operator.namespaceRestriction.enabled=${NAMESPACE_RESTRICTED_OPERATOR}"
    --set "global.etcd.install=${INSTALL_BUNDLED_ETCD}"
    --set "global.grove.install=${ENABLE_GROVE}"
    --set "global.grove.enabled=${ENABLE_GROVE}"
    --set "global.kai-scheduler.install=${ENABLE_KAI_SCHEDULER}"
    --set "global.kai-scheduler.enabled=${ENABLE_KAI_SCHEDULER}"
    --set "nats.config.jetstream.fileStore.pvc.storageClassName=${DYNAMO_STORAGE_CLASS}"
  )

  if [[ "${INSTALL_BUNDLED_ETCD}" == "true" ]]; then
    helm_flags+=(--set "etcd.persistence.storageClass=${DYNAMO_STORAGE_CLASS}")
  fi

  if [[ -n "${PROMETHEUS_ENDPOINT}" ]]; then
    helm_flags+=(--set-string "dynamo-operator.dynamo.metrics.prometheusEndpoint=${PROMETHEUS_ENDPOINT}")
  fi

  log "Step 4: Install or upgrade Dynamo Platform ${CHART_VERSION}"
  helm upgrade --install "${RELEASE_NAME}" "${DYNAMO_CHART_ARCHIVE}" \
    -n "${NAMESPACE}" "${helm_flags[@]}"

  remove_operator_enable_webhooks_flag_if_present "${NAMESPACE}"
}

verify_dynamo_platform() {
  log "Step 5: Verify Dynamo operator webhook endpoint is ready"
  kubectl -n "${NAMESPACE}" rollout status "deploy/${DYNAMO_OPERATOR_DEPLOYMENT}" \
    --timeout="${OPERATOR_WEBHOOK_TIMEOUT}s"

  if ! wait_for_service_endpoints "${NAMESPACE}" "${DYNAMO_OPERATOR_WEBHOOK_SERVICE}" "${OPERATOR_WEBHOOK_TIMEOUT}"; then
    echo "ERROR: Dynamo webhook service has no ready endpoints after install." >&2
    echo "Debug:" >&2
    echo "  kubectl -n ${NAMESPACE} get pods -o wide | grep -E 'dynamo-operator|controller-manager'" >&2
    echo "  kubectl -n ${NAMESPACE} get svc ${DYNAMO_OPERATOR_WEBHOOK_SERVICE} -o yaml" >&2
    echo "  kubectl -n ${NAMESPACE} get endpoints ${DYNAMO_OPERATOR_WEBHOOK_SERVICE} -o yaml" >&2
    echo "  kubectl -n ${NAMESPACE} logs deploy/${DYNAMO_OPERATOR_DEPLOYMENT} -c manager --tail=200" >&2
    exit 1
  fi

  log "Step 6: Verify pods and PVCs"
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

  log "Final Dynamo status"
  helm list -n "${NAMESPACE}"
  helm history "${RELEASE_NAME}" -n "${NAMESPACE}" || true
  kubectl get crd | grep -i dynamo || true
  kubectl get pods -n "${NAMESPACE}" -o wide
  kubectl get svc -n "${NAMESPACE}" | grep -E -i 'webhook|dynamo-operator|etcd|nats' || true
  kubectl get statefulset -n "${NAMESPACE}" || true
  kubectl get pvc -n "${NAMESPACE}" || true
}

install_gpu_operator() {
  if [[ "${INSTALL_GPU_OPERATOR}" != "true" ]]; then
    log "Step 7: Skip NVIDIA GPU Operator"
    echo "INSTALL_GPU_OPERATOR=${INSTALL_GPU_OPERATOR}; skipping GPU Operator installation and GPU verification."
    return 0
  fi

  log "Step 7: Install NVIDIA GPU Operator (enables nvidia.com/gpu in Kubernetes)"

  log "Adding/updating NVIDIA Helm repo (GPU Operator chart source)"
  helm repo add "${NVIDIA_HELM_REPO_NAME}" "${NVIDIA_HELM_REPO_URL}" >/dev/null 2>&1 || true
  helm repo update >/dev/null

  log "Creating GPU Operator namespace"
  kubectl create namespace "${GPU_OPERATOR_NS}" >/dev/null 2>&1 || true

  log "Installing/upgrading GPU Operator (containerd runtime, with --wait)"
  helm upgrade --install "${GPU_OPERATOR_RELEASE}" "${NVIDIA_HELM_REPO_NAME}/gpu-operator" \
    -n "${GPU_OPERATOR_NS}" \
    --set operator.defaultRuntime=containerd \
    --wait \
    --timeout "${GPU_OPERATOR_HELM_TIMEOUT}"

  log "Waiting for GPU Operator pods to be Running/Completed"
  for _ in {1..180}; do
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
    if [[ "${REQUIRE_GPUS}" != "true" ]]; then
      echo "WARN: Kubernetes shows 0 GPUs allocatable, but REQUIRE_GPUS=${REQUIRE_GPUS}; continuing." >&2
      return 0
    fi

    echo "ERROR: Kubernetes still shows 0 GPUs allocatable. GPU Operator may not be fully ready." >&2
    echo "Debug:" >&2
    echo "  kubectl get pods -n ${GPU_OPERATOR_NS}" >&2
    echo "  kubectl -n ${GPU_OPERATOR_NS} get events --sort-by=.lastTimestamp | tail -n 50" >&2
    exit 1
  fi

  log "GPU Operator is installed and GPUs are available to schedule"
}

# -----------------------------
# Main
# -----------------------------

log "Pre-flight: verify required commands"
need_cmd kubectl
need_cmd helm
need_cmd tar
need_cmd grep
need_cmd awk
need_cmd cksum

validate_bool NAMESPACE_RESTRICTED_OPERATOR "${NAMESPACE_RESTRICTED_OPERATOR}"
validate_bool SKIP_CRDS "${SKIP_CRDS}"
validate_bool INSTALL_BUNDLED_ETCD "${INSTALL_BUNDLED_ETCD}"
validate_bool ENABLE_GROVE "${ENABLE_GROVE}"
validate_bool ENABLE_KAI_SCHEDULER "${ENABLE_KAI_SCHEDULER}"
validate_bool INSTALL_GPU_OPERATOR "${INSTALL_GPU_OPERATOR}"
validate_bool REQUIRE_GPUS "${REQUIRE_GPUS}"
validate_bool RESUME_INSTALL "${RESUME_INSTALL}"
validate_bool RESET_RESUME_STATE "${RESET_RESUME_STATE}"

configure_resume_state

log "Pre-flight: verify kubectl can talk to the cluster"
kubectl version --client >/dev/null
kubectl get nodes >/dev/null

log "Using configuration:"
echo "  NAMESPACE=${NAMESPACE}"
echo "  RELEASE_NAME=${RELEASE_NAME}"
echo "  RELEASE_VERSION=${RELEASE_VERSION}"
echo "  CHART_VERSION=${CHART_VERSION}"
echo "  CHART_URL=${CHART_URL}"
echo "  NAMESPACE_RESTRICTED_OPERATOR=${NAMESPACE_RESTRICTED_OPERATOR}"
echo "  SKIP_CRDS=${SKIP_CRDS}"
echo "  DYNAMO_STORAGE_CLASS=${DYNAMO_STORAGE_CLASS}"
echo "  INSTALL_BUNDLED_ETCD=${INSTALL_BUNDLED_ETCD}"
echo "  ENABLE_GROVE=${ENABLE_GROVE}"
echo "  ENABLE_KAI_SCHEDULER=${ENABLE_KAI_SCHEDULER}"
echo "  PROMETHEUS_ENDPOINT=${PROMETHEUS_ENDPOINT}"
echo "  PLATFORM_HELM_TIMEOUT=${PLATFORM_HELM_TIMEOUT}"
echo "  OPERATOR_WEBHOOK_TIMEOUT=${OPERATOR_WEBHOOK_TIMEOUT}"
echo "  INSTALL_GPU_OPERATOR=${INSTALL_GPU_OPERATOR}"
echo "  REQUIRE_GPUS=${REQUIRE_GPUS}"
echo "  GPU_OPERATOR_NS=${GPU_OPERATOR_NS}"
echo "  GPU_OPERATOR_RELEASE=${GPU_OPERATOR_RELEASE}"
echo "  GPU_OPERATOR_HELM_TIMEOUT=${GPU_OPERATOR_HELM_TIMEOUT}"
echo "  GPU_ALLOCATABLE_WAIT_ATTEMPTS=${GPU_ALLOCATABLE_WAIT_ATTEMPTS}"
echo "  GPU_ALLOCATABLE_WAIT_INTERVAL=${GPU_ALLOCATABLE_WAIT_INTERVAL}"
echo "  RESUME_INSTALL=${RESUME_INSTALL}"
echo "  RESET_RESUME_STATE=${RESET_RESUME_STATE}"
echo "  DYNAMO_INSTALL_STATE_DIR=${DYNAMO_INSTALL_STATE_DIR}"
echo "  DYNAMO_WORKDIR=${DYNAMO_WORKDIR}"

run_step "storage_class" ensure_dynamo_storage_class
create_hf_token_secret_if_requested
run_step "snapshot_existing_release" snapshot_existing_release

prepare_dynamo_chart "${DYNAMO_WORKDIR}"
run_step "apply_dynamo_crds" apply_dynamo_crds
run_step "install_or_upgrade_dynamo_platform" install_or_upgrade_dynamo_platform
run_step "verify_dynamo_platform" verify_dynamo_platform

log "Dynamo Platform ${CHART_VERSION} installed/upgraded"

if [[ -n "${PROMETHEUS_ENDPOINT}" ]]; then
  echo
  echo "Prometheus endpoint configured:"
  echo "  ${PROMETHEUS_ENDPOINT}"
fi

run_step "install_gpu_operator" install_gpu_operator

echo "Next: deploy a Dynamo GPU workload and ensure nvcr.io image pull works."
