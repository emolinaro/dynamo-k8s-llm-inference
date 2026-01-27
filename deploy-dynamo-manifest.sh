#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Deploy a model using Dynamo agg/disagg manifest files
#
# This script:
#  1) Clones/updates the Dynamo GitHub repo
#  2) Locates the appropriate manifest file (agg.yaml or disagg.yaml)
#  3) Patches the model configuration
#  4) Applies the manifest to Kubernetes
#  5) Waits for deployment to be ready
#
# Usage:
#   ./deploy-dynamo-manifest.sh --backend vllm --model Qwen/Qwen3-0.6B --mode agg
#   ./deploy-dynamo-manifest.sh --backend vllm --model meta-llama/Llama-3.2-3B --mode disagg
#
# Options:
#   --backend BACKEND     Backend to use (vllm, sglang, trtllm) [required]
#   --model MODEL         HuggingFace model identifier [required]
#   --mode MODE           Deployment mode: agg or disagg [default: agg]
#   --namespace NS        Kubernetes namespace [default: dynamo-system]
#   --runtime-tag TAG     Runtime tag to use [default: 0.8.1]
#   --runtime-image IMG   Full runtime image override (e.g. nvcr.io/nvidia/ai-dynamo/sglang-runtime:0.8.1)
#   --repo-url URL        Dynamo repo URL [default: https://github.com/ai-dynamo/dynamo.git]
#   --repo-dir DIR        Local directory for Dynamo repo [default: dynamo]
#   --hf-token TOKEN      HuggingFace token for private/gated models [optional]
#   --nodeport PORT       Fixed NodePort (30000-32767) or auto-assign if not set [optional]
#   --name-prefix PREFIX  Prefix for all resource names (enables multiple deployments) [optional]
#   --no-wait             Don't wait for pods to be ready
###############################################################################

# -----------------------------
# Default Configuration
# -----------------------------
NAMESPACE="${NAMESPACE:-dynamo-system}"
MODE="${MODE:-agg}"
BACKEND="${BACKEND:-}"
MODEL="${MODEL:-}"
RUNTIME_TAG="${RUNTIME_TAG:-0.8.1}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-}"
DYNAMO_REPO_URL="${DYNAMO_REPO_URL:-https://github.com/ai-dynamo/dynamo.git}"
DYNAMO_REPO_DIR="${DYNAMO_REPO_DIR:-dynamo}"
HF_TOKEN="${HF_TOKEN:-}"
NODEPORT="${NODEPORT:-}"
NAME_PREFIX="${NAME_PREFIX:-}"
NO_WAIT="${NO_WAIT:-false}"

PODS_TIMEOUT="${PODS_TIMEOUT:-1200}"
ENDPOINTS_TIMEOUT="${ENDPOINTS_TIMEOUT:-300}"
SERVICES_TIMEOUT="${SERVICES_TIMEOUT:-180}"
DEPLOYMENTS_TIMEOUT="${DEPLOYMENTS_TIMEOUT:-180}"

# -----------------------------
# Helpers
# -----------------------------
log() { echo -e "\n==> $*\n"; }
warn() { echo -e "WARN: $*\n" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }


usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Required:
  --backend BACKEND     Backend to use (vllm, sglang, trtllm)
  --model MODEL         HuggingFace model identifier

Optional:
  --mode MODE           Deployment mode: agg or disagg [default: agg]
  --namespace NS        Kubernetes namespace [default: dynamo-system]
  --runtime-tag TAG     Runtime tag to use [default: 0.8.1]
  --runtime-image IMG   Full runtime image override (e.g. nvcr.io/nvidia/ai-dynamo/sglang-runtime:0.8.1)
  --repo-url URL        Dynamo repo URL [default: https://github.com/ai-dynamo/dynamo.git]
  --repo-dir DIR        Local directory for Dynamo repo [default: dynamo]
  --hf-token TOKEN      HuggingFace token for private/gated models
  --nodeport PORT       Fixed NodePort (30000-32767) or auto-assign if not set
  --name-prefix PREFIX  Prefix for all resource names (enables multiple deployments)
  --no-wait             Don't wait for pods to be ready

Examples:
  $0 --backend vllm --model Qwen/Qwen3-0.6B --mode agg
  $0 --backend vllm --model meta-llama/Llama-3.2-3B --mode disagg
  $0 --backend sglang --model Qwen/Qwen3-0.6B --mode agg --namespace my-ns
  $0 --backend vllm --model Qwen/Qwen3-0.6B --mode agg --name-prefix qwen-model
  $0 --backend vllm --model meta-llama/Llama-3.2-3B --mode agg --name-prefix llama-model
EOF
  exit 1
}

wait_pod_ready_by_grep() {
  local ns="$1" pattern="$2" timeout="$3"
  local start; start="$(date +%s)"
  while true; do
    local line
    line="$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk -v pat="$pattern" '$1 ~ pat {print; exit}')"
    if [[ -n "$line" ]]; then
      local ready status
      ready="$(echo "$line" | awk '{print $2}')"
      status="$(echo "$line" | awk '{print $3}')"
      if [[ "$status" == "Running" && "$ready" == "1/1" ]]; then
        return 0
      fi
    fi
    local now; now="$(date +%s)"
    if (( now - start > timeout )); then
      kubectl -n "$ns" get pods -o wide || true
      return 1
    fi
    sleep 5
  done
}

wait_endpoints() {
  local ns="$1" svc="$2" timeout="$3"
  local start; start="$(date +%s)"
  while true; do
    if kubectl -n "$ns" get endpoints "$svc" -o jsonpath='{.subsets[0].addresses[0].ip}' >/dev/null 2>&1; then
      return 0
    fi
    local now; now="$(date +%s)"
    if (( now - start > timeout )); then
      kubectl -n "$ns" get endpoints "$svc" -o yaml || true
      return 1
    fi
    sleep 5
  done
}

# -----------------------------
# Parse Arguments
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      BACKEND="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --runtime-tag)
      RUNTIME_TAG="$2"
      shift 2
      ;;
    --runtime-image)
      RUNTIME_IMAGE="$2"
      shift 2
      ;;
    --repo-url)
      DYNAMO_REPO_URL="$2"
      shift 2
      ;;
    --repo-dir)
      DYNAMO_REPO_DIR="$2"
      shift 2
      ;;
    --hf-token)
      HF_TOKEN="$2"
      shift 2
      ;;
    --nodeport)
      NODEPORT="$2"
      shift 2
      ;;
    --name-prefix)
      NAME_PREFIX="$2"
      shift 2
      ;;
    --no-wait)
      NO_WAIT="true"
      shift
      ;;
    --help|-h)
      usage
      ;;
    *)
      die "Unknown option: $1\n$(usage)"
      ;;
  esac
done

# -----------------------------
# Validate Required Arguments
# -----------------------------
[[ -n "${BACKEND}" ]] || die "--backend is required\n$(usage)"
[[ -n "${MODEL}" ]] || die "--model is required\n$(usage)"

if [[ "${MODE}" != "agg" && "${MODE}" != "disagg" ]]; then
  die "Invalid mode: ${MODE}. Must be 'agg' or 'disagg'"
fi

# -----------------------------
# Pre-flight
# -----------------------------
log "Pre-flight checks"
need kubectl
need git

kubectl get nodes >/dev/null 2>&1 || die "Cannot connect to Kubernetes cluster"

log "Verify GPUs are allocatable"
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable.nvidia\\.com/gpu || true
GPU_TOTAL="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
  | awk 'BEGIN{s=0} {if($1!=""){s+=$1}} END{print s}')"
[[ "${GPU_TOTAL}" -gt 0 ]] || warn "No GPUs allocatable (nvidia.com/gpu missing/0)"

# -----------------------------
# Clone/Update Dynamo Repo
# -----------------------------
log "Ensure Dynamo repo exists"
if [[ ! -d "${DYNAMO_REPO_DIR}/.git" ]]; then
  log "Cloning Dynamo repo from ${DYNAMO_REPO_URL}"
  git clone "${DYNAMO_REPO_URL}" "${DYNAMO_REPO_DIR}"
else
  log "Updating existing Dynamo repo"
  (cd "${DYNAMO_REPO_DIR}" && git fetch --all && git pull || true)
fi

# -----------------------------
# Locate Manifest File
# -----------------------------
MANIFEST_REL="examples/backends/${BACKEND}/deploy/${MODE}.yaml"
MANIFEST="${DYNAMO_REPO_DIR}/${MANIFEST_REL}"

if [[ ! -f "${MANIFEST}" ]]; then
  die "Manifest file not found: ${MANIFEST}\nAvailable backends: $(ls -1 "${DYNAMO_REPO_DIR}/examples/backends/" 2>/dev/null | tr '\n' ' ' || echo 'unknown')"
fi

log "Using manifest: ${MANIFEST}"

# -----------------------------
# Create Namespace
# -----------------------------
log "Ensure namespace exists: ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# -----------------------------
# Create HF Token Secret (if provided)
# -----------------------------
if [[ -n "${HF_TOKEN}" ]]; then
  log "Creating HuggingFace token secret with HF_TOKEN key"
  # Create secret with HF_TOKEN key so envFromSecret creates HF_TOKEN env var
  # Also include 'token' key for backward compatibility
  kubectl -n "${NAMESPACE}" create secret generic hf-token-secret \
    --from-literal=HF_TOKEN="${HF_TOKEN}" \
    --from-literal=HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}" \
    --from-literal=token="${HF_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
else
  log "Creating dummy HuggingFace token secret (for manifest compatibility)"
  kubectl -n "${NAMESPACE}" create secret generic hf-token-secret \
    --from-literal=HF_TOKEN=dummy \
    --from-literal=HUGGING_FACE_HUB_TOKEN=dummy \
    --from-literal=token=dummy \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

# -----------------------------
# Patch Manifest
# -----------------------------
log "Patching manifest for model: ${MODEL}, runtime-tag: ${RUNTIME_TAG}"
PATCHED_MANIFEST="$(mktemp)"
trap "rm -f ${PATCHED_MANIFEST}" EXIT

# Copy manifest to temp file
cp "${MANIFEST}" "${PATCHED_MANIFEST}"

# Patch runtime image/tag
if [[ -n "${RUNTIME_IMAGE}" ]]; then
  log "Overriding runtime image: ${RUNTIME_IMAGE}"
  RUNTIME_IMAGE_SED="$(printf '%s' "${RUNTIME_IMAGE}" | sed -e 's/[\\/&]/\\&/g')"
  sed -i.bak -E "s|(^[[:space:]]*image:[[:space:]]*)(\"?)[^\"#]*(vllm-runtime|sglang-runtime|tensorrtllm-runtime)[^\"#]*(\"?)|\\1\\2${RUNTIME_IMAGE_SED}\\4|g" \
    "${PATCHED_MANIFEST}" 2>/dev/null || true
else
  # Replace my-registry placeholders with official registry and tag (quoted or unquoted)
  sed -i.bak -E "s|(^[[:space:]]*image:[[:space:]]*)(\"?)my-registry/(vllm-runtime|sglang-runtime|tensorrtllm-runtime):[^\"[:space:]#]+(\"?)|\\1\\2nvcr.io/nvidia/ai-dynamo/\\3:${RUNTIME_TAG}\\4|g" \
    "${PATCHED_MANIFEST}" 2>/dev/null || true
  # Replace official runtime images with desired tag
  sed -i.bak -E "s|(^[[:space:]]*image:[[:space:]]*nvcr.io/nvidia/ai-dynamo/(vllm-runtime|sglang-runtime|tensorrtllm-runtime)):[^[:space:]#]+|\\1:${RUNTIME_TAG}|g" \
    "${PATCHED_MANIFEST}" 2>/dev/null || true
  # Fallback: replace :my-tag anywhere
  sed -i.bak "s/:my-tag/:${RUNTIME_TAG}/g" "${PATCHED_MANIFEST}" 2>/dev/null || true
fi

# Fallback: if any my-registry images remain, replace registry and tag
if grep -q "my-registry/" "${PATCHED_MANIFEST}"; then
  warn "Runtime image still references my-registry; applying fallback registry replacement"
  sed -i.bak -E "s|(^[[:space:]]*image:[[:space:]]*)(\"?)my-registry/([^\"[:space:]#]+)(\"?)|\\1\\2nvcr.io/nvidia/ai-dynamo/\\3\\4|g" \
    "${PATCHED_MANIFEST}" 2>/dev/null || true
  sed -i.bak -E "s|(^[[:space:]]*image:[[:space:]]*nvcr.io/nvidia/ai-dynamo/[^\"[:space:]#]+):my-tag|\\1:${RUNTIME_TAG}|g" \
    "${PATCHED_MANIFEST}" 2>/dev/null || true
fi
rm -f "${PATCHED_MANIFEST}.bak"

# Patch HF_TOKEN in manifest if provided
# Dynamo manifests typically reference hf-token-secret, we need to ensure it's used
if [[ -n "${HF_TOKEN}" ]]; then
  log "Ensuring HF_TOKEN is configured in manifest"
  # Check if manifest already references the secret
  if ! grep -q "hf-token-secret\|HF_TOKEN\|HUGGING_FACE_HUB_TOKEN" "${PATCHED_MANIFEST}"; then
    warn "Manifest doesn't appear to reference HF token. Token may need to be added manually to worker specs."
  fi
fi

# Patch model configuration
# Common patterns in Dynamo manifests:
# 1. Environment variable: MODEL_NAME or MODEL
# 2. Args: --model MODEL_NAME (most common in DynamoGraphDeployment)
# 3. Spec fields: model: MODEL_NAME

MODEL_PATCHED="false"
# Escape model name for sed replacement (handle &, \, /)
MODEL_SED="$(printf '%s' "${MODEL}" | sed -e 's/[\\/&]/\\&/g')"

# Try to patch model in various common locations
if grep -qE "(MODEL_NAME|MODEL|--model|--model-path|--served-model-name|model:)" "${PATCHED_MANIFEST}"; then
  # Backend-specific patching based on detected patterns
  
  # Patch common CLI flags (handles list format, inline, and equals form)
  for flag in --model --model-path --served-model-name; do
    # YAML list format: "- --flag" then "- value"
    if sed -i.bak -E "/^[[:space:]]*-[[:space:]]+${flag}[[:space:]]*$/{n;s|^([[:space:]]*-[[:space:]]+)[^[:space:]#]+|\1${MODEL_SED}|}" "${PATCHED_MANIFEST}" 2>/dev/null; then
      MODEL_PATCHED="true"
    fi
    # Inline format: "- --flag value"
    if sed -i.bak -E "s|(-[[:space:]]+${flag}[[:space:]]+)[^[:space:]#]+|\1${MODEL_SED}|g" "${PATCHED_MANIFEST}" 2>/dev/null; then
      MODEL_PATCHED="true"
    fi
    # Equals format: "--flag=value" (including JSON/YAML flow lists)
    if sed -i.bak -E "s|(${flag}=)[^\"'[:space:],]+|\\1${MODEL_SED}|g" "${PATCHED_MANIFEST}" 2>/dev/null; then
      MODEL_PATCHED="true"
    fi
    # Equals format with quotes: --flag="value" or --flag='value'
    if sed -i.bak -E "s|(${flag}=\")([^\"]+)(\")|\\1${MODEL_SED}\\3|g" "${PATCHED_MANIFEST}" 2>/dev/null; then
      MODEL_PATCHED="true"
    fi
    if sed -i.bak -E "s|(${flag}=')([^']+)(')|\\1${MODEL_SED}\\3|g" "${PATCHED_MANIFEST}" 2>/dev/null; then
      MODEL_PATCHED="true"
    fi
    # Flow list format: ["--flag", "value"]
    if sed -i.bak -E "s|(\"${flag}\"[[:space:]]*,[[:space:]]*\")([^\"]+)(\")|\\1${MODEL_SED}\\3|g" "${PATCHED_MANIFEST}" 2>/dev/null; then
      MODEL_PATCHED="true"
    fi
  done
  
  # Patch environment variables (handle both KEY: value and name/value pairs)
  if sed -i.bak -E "s|(MODEL_NAME:[[:space:]]+)[^[:space:]#]+|\\1${MODEL_SED}|g" "${PATCHED_MANIFEST}" 2>/dev/null; then
    MODEL_PATCHED="true"
  fi
  if sed -i.bak -E "s|(MODEL:[[:space:]]+)[^[:space:]#]+|\\1${MODEL_SED}|g" "${PATCHED_MANIFEST}" 2>/dev/null; then
    MODEL_PATCHED="true"
  fi
  # name: MODEL_NAME / MODEL with following value: line
  if sed -i.bak -E "/name:[[:space:]]*(MODEL_NAME|MODEL|MODEL_ID)[[:space:]]*$/{n;s|^([[:space:]]*value:[[:space:]]+).*|\\1${MODEL_SED}|}" "${PATCHED_MANIFEST}" 2>/dev/null; then
    MODEL_PATCHED="true"
  fi
  
  # Patch YAML spec fields (model: <value> in spec sections)
  # Be more careful - only replace standalone model: fields, not nested ones
  if sed -i.bak -E "s|(^[[:space:]]*model:[[:space:]]+)[^[:space:]#]+|\\1${MODEL_SED}|g" "${PATCHED_MANIFEST}" 2>/dev/null; then
    MODEL_PATCHED="true"
  fi
  
  rm -f "${PATCHED_MANIFEST}.bak" 2>/dev/null || true
  
  # Verify the model was actually patched
  if grep -qF "${MODEL}" "${PATCHED_MANIFEST}"; then
    log "Model configuration patched in manifest: ${MODEL}"
    MODEL_PATCHED="true"
  elif [[ "${MODEL_PATCHED}" == "true" ]]; then
    warn "Model patching attempted but verification failed. Check manifest manually."
  else
    warn "Could not find or patch model configuration pattern in manifest."
  fi
else
  warn "Could not find model configuration pattern in manifest. Model may need to be set manually after deployment."
fi

# Patch resource names with prefix (if provided)
if [[ -n "${NAME_PREFIX}" ]]; then
  log "Applying name prefix '${NAME_PREFIX}' to all resources"
  
  # Validate prefix (Kubernetes names must be lowercase alphanumeric with hyphens)
  if [[ ! "${NAME_PREFIX}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    die "Invalid name prefix '${NAME_PREFIX}'. Must be lowercase alphanumeric with hyphens, start and end with alphanumeric."
  fi
  
  # Step 1: Prefix all metadata.name fields
  # Match lines like: "  name: some-name" or "    name: some-name"
  # This handles the most common case - resource names in metadata.name
  sed -E "s|^([[:space:]]+)name:[[:space:]]+([^[:space:]#\"]+)([[:space:]]*#.*)?$|\1name: ${NAME_PREFIX}-\2\3|g" \
    "${PATCHED_MANIFEST}" > "${PATCHED_MANIFEST}.tmp" 2>/dev/null || cp "${PATCHED_MANIFEST}" "${PATCHED_MANIFEST}.tmp"
  mv "${PATCHED_MANIFEST}.tmp" "${PATCHED_MANIFEST}"
  
  # Step 2: Update common label values that typically match resource names
  # This updates app: and name: label values in matchLabels and labels sections
  # We do this by finding the original names and replacing them
  # Extract resource names that were just prefixed
  PREFIXED_NAMES=$(grep -E "^[[:space:]]+name:[[:space:]]+${NAME_PREFIX}-" "${PATCHED_MANIFEST}" | \
    sed -E "s|^[[:space:]]+name:[[:space:]]+${NAME_PREFIX}-([^[:space:]#]+).*|\1|" | sort -u)
  
  # Step 3: Update selectors and labels to match prefixed names
  # Update app: and name: label values in matchLabels and labels
  for orig_name in ${PREFIXED_NAMES}; do
    # Update app: labels (most common selector pattern)
    sed -i.bak "s|\(app:[[:space:]]*\)${orig_name}\([[:space:]#$]\)|\1${NAME_PREFIX}-${orig_name}\2|g" "${PATCHED_MANIFEST}" 2>/dev/null || true
    # Update name: labels
    sed -i.bak "s|\(name:[[:space:]]*\)${orig_name}\([[:space:]#$]\)|\1${NAME_PREFIX}-${orig_name}\2|g" "${PATCHED_MANIFEST}" 2>/dev/null || true
  done
  
  # Clean up backup files
  rm -f "${PATCHED_MANIFEST}.bak" 2>/dev/null || true
  
  log "Name prefix applied. Resources will be prefixed with '${NAME_PREFIX}-'"
  log "Example: If original name was 'vllm-agg-frontend', it's now '${NAME_PREFIX}-vllm-agg-frontend'"
  warn "Note: Some backend-specific configurations may need manual adjustment after deployment"
else
  log "No name prefix specified, using default resource names from manifest"
fi

# Verify runtime tag was patched
if ! grep -q ":${RUNTIME_TAG}" "${PATCHED_MANIFEST}"; then
  warn "Runtime tag patch may have failed. Manifest may use a different tag pattern."
fi

log "Patched manifest saved to: ${PATCHED_MANIFEST}"

# -----------------------------
# Apply Manifest
# -----------------------------
log "Applying manifest to namespace ${NAMESPACE}"
kubectl apply -n "${NAMESPACE}" -f "${PATCHED_MANIFEST}"

# Extract resource and service names from the manifest we just applied
MANIFEST_RESOURCE_NAMES="$(grep -E "^[[:space:]]*name:[[:space:]]+" "${PATCHED_MANIFEST}" | \
  sed -E "s|^[[:space:]]*name:[[:space:]]+([^[:space:]#]+).*|\\1|" | sort -u)"

# If name prefix was used, filter to only those resources
if [[ -n "${NAME_PREFIX}" ]]; then
  MANIFEST_RESOURCE_NAMES="$(echo "${MANIFEST_RESOURCE_NAMES}" | grep "^${NAME_PREFIX}-" || echo "")"
fi

MANIFEST_SERVICE_NAMES="$(awk '
  /^[[:space:]]*kind:[[:space:]]*Service[[:space:]]*$/ {in_svc=1; next}
  in_svc && /^[[:space:]]*name:[[:space:]]*/ {
    line=$0
    sub(/^[[:space:]]*name:[[:space:]]*/,"",line)
    sub(/[[:space:]#].*$/,"",line)
    if (line != "") print line
    in_svc=0
  }
' "${PATCHED_MANIFEST}" | sort -u)"

# Extract DynamoGraphDeployment name (if present)
DGD_NAME="$(awk '
  /^[[:space:]]*kind:[[:space:]]*DynamoGraphDeployment[[:space:]]*$/ {in_dgd=1; next}
  in_dgd && /^[[:space:]]*name:[[:space:]]*/ {
    line=$0
    sub(/^[[:space:]]*name:[[:space:]]*/,"",line)
    sub(/[[:space:]#].*$/,"",line)
    if (line != "") print line
    exit
  }
' "${PATCHED_MANIFEST}")"

# Ensure hf-token-secret is wired into DGD services so frontend sees the token
if [[ -n "${HF_TOKEN}" && -n "${DGD_NAME}" ]]; then
  log "Ensuring hf-token-secret is set for DynamoGraphDeployment frontend/workers"
  kubectl -n "${NAMESPACE}" patch dynamographdeployment "${DGD_NAME}" --type='merge' \
    -p='{"spec":{"services":{"Frontend":{"envFromSecret":"hf-token-secret"}}}}' \
    >/dev/null 2>&1 || warn "Could not add envFromSecret to DynamoGraphDeployment Frontend"
  kubectl -n "${NAMESPACE}" patch dynamographdeployment "${DGD_NAME}" --type='merge' \
    -p='{"spec":{"services":{"VllmDecodeWorker":{"envFromSecret":"hf-token-secret"}}}}' \
    >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" patch dynamographdeployment "${DGD_NAME}" --type='merge' \
    -p='{"spec":{"services":{"SglangDecodeWorker":{"envFromSecret":"hf-token-secret"}}}}' \
    >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" patch dynamographdeployment "${DGD_NAME}" --type='merge' \
    -p='{"spec":{"services":{"TrtllmDecodeWorker":{"envFromSecret":"hf-token-secret"}}}}' \
    >/dev/null 2>&1 || true
fi

# Resolve current deployment deployments (use labels if DGD found)
CURRENT_DEPLOYMENTS=""
if [[ -n "${DGD_NAME}" ]]; then
  DYNAMO_LABEL="${NAMESPACE}-${DGD_NAME}"
  log "Waiting for deployments created by DynamoGraphDeployment: ${DGD_NAME}"
  start_ts="$(date +%s)"
  while true; do
    CURRENT_DEPLOYMENTS="$(kubectl -n "${NAMESPACE}" get deploy -l "nvidia.com/dynamo-namespace=${DYNAMO_LABEL}" -o name --no-headers 2>/dev/null || true)"
    if [[ -n "${CURRENT_DEPLOYMENTS}" ]]; then
      break
    fi
    now_ts="$(date +%s)"
    if (( now_ts - start_ts > DEPLOYMENTS_TIMEOUT )); then
      warn "Timed out waiting for deployments for ${DGD_NAME}."
      break
    fi
    sleep 3
  done
else
  # Fallback: match deployments by resource name prefixes
  if [[ -n "${MANIFEST_RESOURCE_NAMES}" ]]; then
    CURRENT_DEPLOYMENTS="$(kubectl -n "${NAMESPACE}" get deploy -o name --no-headers 2>/dev/null | \
      awk -v names="${MANIFEST_RESOURCE_NAMES}" '
        BEGIN{
          split(names, a, " ");
          for (i in a) if (a[i] != "") pats[a[i]] = 1;
        }
        {
          dep=$1
          sub(/^deployment\//,"",dep)
          for (p in pats) {
            if (index(dep, p) == 1) { print "deployment/" dep; next }
          }
        }' | sort -u)"
  fi
fi

# Resolve current deployment services. If Services aren't in the manifest
# (common when a DynamoGraphDeployment generates them), match by prefix.
CURRENT_SERVICE_NAMES=""
if [[ -n "${MANIFEST_SERVICE_NAMES}" ]]; then
  CURRENT_SERVICE_NAMES="${MANIFEST_SERVICE_NAMES}"
elif [[ -n "${MANIFEST_RESOURCE_NAMES}" ]]; then
  log "Waiting for services created by this deployment..."
  start_ts="$(date +%s)"
  while true; do
    CURRENT_SERVICE_NAMES="$(kubectl -n "${NAMESPACE}" get svc --no-headers 2>/dev/null | \
      awk -v names="${MANIFEST_RESOURCE_NAMES}" '
        BEGIN{
          split(names, a, " ");
          for (i in a) if (a[i] != "") pats[a[i]] = 1;
        }
        {
          svc=$1
          if (svc ~ /^dynamo-platform-/ || svc ~ /-operator-/ || svc=="etcd" || svc=="nats") next
          for (p in pats) {
            if (index(svc, p) == 1) { print svc; next }
          }
        }' | sort -u)"
    if [[ -n "${CURRENT_SERVICE_NAMES}" ]]; then
      break
    fi
    now_ts="$(date +%s)"
    if (( now_ts - start_ts > SERVICES_TIMEOUT )); then
      warn "Timed out waiting for services for this deployment."
      break
    fi
    sleep 3
  done
fi

# Post-apply: If model wasn't patched in manifest, try to patch via kubectl
# This is a fallback for manifests that don't have model config in the YAML
# Only patch resources that were created by THIS deployment (from the manifest)
if ! grep -qF "${MODEL}" "${PATCHED_MANIFEST}"; then
  log "Model not found in patched manifest, attempting post-apply patching via kubectl"
  
  # Try to patch DynamoGraphDeployment CRDs first (Dynamo-specific)
  for dgd_name in ${MANIFEST_RESOURCE_NAMES}; do
    if kubectl -n "${NAMESPACE}" get dynamographdeployment "${dgd_name}" >/dev/null 2>&1; then
      log "Found DynamoGraphDeployment: ${dgd_name}"

      # If HF_TOKEN was provided, add it as an environment variable to workers
      if [[ -n "${HF_TOKEN}" ]]; then
        # Try to patch the DynamoGraphDeployment to add HF_TOKEN env var
        # The exact path depends on the DynamoGraphDeployment structure
        # Common paths: spec.workers[].env or spec.workers[].container.env
        kubectl patch dynamographdeployment "${dgd_name}" -n "${NAMESPACE}" --type='json' \
          -p='[{"op":"add","path":"/spec/workers/0/env/-","value":{"name":"HF_TOKEN","valueFrom":{"secretKeyRef":{"name":"hf-token-secret","key":"token"}}}}]' \
          2>/dev/null || \
        kubectl patch dynamographdeployment "${dgd_name}" -n "${NAMESPACE}" --type='json' \
          -p='[{"op":"add","path":"/spec/workers/0/container/env/-","value":{"name":"HF_TOKEN","valueFrom":{"secretKeyRef":{"name":"hf-token-secret","key":"token"}}}}]' \
          2>/dev/null || \
        warn "Could not automatically add HF_TOKEN to DynamoGraphDeployment. You may need to add it manually to the manifest."
      fi

      warn "DynamoGraphDeployment model configuration should be set in the manifest. Verify model was patched correctly."
      continue
    fi
  done
  
  # Patch regular Deployments and StatefulSets that match our manifest
  for resource_name in ${MANIFEST_RESOURCE_NAMES}; do
    # Try deployment first
    if kubectl -n "${NAMESPACE}" get deployment "${resource_name}" >/dev/null 2>&1; then
      resource="deployment/${resource_name}"
      CURRENT_ENV=$(kubectl -n "${NAMESPACE}" get "${resource}" -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null || echo "")
      if [[ -n "${CURRENT_ENV}" ]] && ! echo "${CURRENT_ENV}" | grep -q "MODEL"; then
        log "Adding MODEL env var to ${resource}"
        kubectl -n "${NAMESPACE}" patch "${resource}" --type='json' \
          -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"MODEL","value":"'${MODEL}'"}}]' \
          2>/dev/null || warn "Failed to patch ${resource}"
      fi
    # Try statefulset
    elif kubectl -n "${NAMESPACE}" get statefulset "${resource_name}" >/dev/null 2>&1; then
      resource="statefulset/${resource_name}"
      CURRENT_ENV=$(kubectl -n "${NAMESPACE}" get "${resource}" -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null || echo "")
      if [[ -n "${CURRENT_ENV}" ]] && ! echo "${CURRENT_ENV}" | grep -q "MODEL"; then
        log "Adding MODEL env var to ${resource}"
        kubectl -n "${NAMESPACE}" patch "${resource}" --type='json' \
          -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"MODEL","value":"'${MODEL}'"}}]' \
          2>/dev/null || warn "Failed to patch ${resource}"
      fi
    fi
  done
fi

# -----------------------------
# Convert Services to NodePort
# -----------------------------
log "Converting services from this deployment to NodePort for external access"

# If no services were found initially, try to find them again (they might have been created by CRD controller)
# This is especially important for DynamoGraphDeployment which creates services asynchronously
if [[ -z "${CURRENT_SERVICE_NAMES}" ]] && [[ -n "${MANIFEST_RESOURCE_NAMES}" ]]; then
  log "Services not found initially, waiting for DynamoGraphDeployment to create them..."
  start_ts="$(date +%s)"
  while true; do
    CURRENT_SERVICE_NAMES="$(kubectl -n "${NAMESPACE}" get svc --no-headers 2>/dev/null | \
      awk -v names="${MANIFEST_RESOURCE_NAMES}" '
        BEGIN{
          split(names, a, " ");
          for (i in a) if (a[i] != "") pats[a[i]] = 1;
        }
        {
          svc=$1
          if (svc ~ /^dynamo-platform-/ || svc ~ /-operator-/ || svc=="etcd" || svc=="nats") next
          for (p in pats) {
            if (index(svc, p) == 1) { print svc; next }
          }
        }' | sort -u)"
    if [[ -n "${CURRENT_SERVICE_NAMES}" ]]; then
      log "Found services: ${CURRENT_SERVICE_NAMES}"
      break
    fi
    now_ts="$(date +%s)"
    if (( now_ts - start_ts > SERVICES_TIMEOUT )); then
      warn "Timed out waiting for services. Trying one more time with broader search..."
      # Last attempt: find any services that match the backend/mode pattern
      BACKEND_MODE_PATTERN="${BACKEND}-${MODE}"
      CURRENT_SERVICE_NAMES="$(kubectl -n "${NAMESPACE}" get svc --no-headers 2>/dev/null | \
        awk -v pattern="${BACKEND_MODE_PATTERN}" '
          {
            svc=$1
            if (svc ~ /^dynamo-platform-/ || svc ~ /-operator-/ || svc=="etcd" || svc=="nats") next
            if (index(svc, pattern) > 0) { print svc }
          }' | sort -u)"
      if [[ -n "${CURRENT_SERVICE_NAMES}" ]]; then
        log "Found services using pattern matching: ${CURRENT_SERVICE_NAMES}"
      else
        warn "No services found. They may be created later by the DynamoGraphDeployment controller."
      fi
      break
    fi
    sleep 3
  done
fi

if [[ -z "${CURRENT_SERVICE_NAMES}" ]]; then
  warn "No services found for current deployment; skipping NodePort conversion"
  warn "Services may be created later. You can manually convert them with:"
  warn "  kubectl patch svc <service-name> -n ${NAMESPACE} --type='json' -p='[{\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"}]'"
else
  for svc_name in ${CURRENT_SERVICE_NAMES}; do
    svc="service/${svc_name}"
    if ! kubectl -n "${NAMESPACE}" get "${svc}" >/dev/null 2>&1; then
      warn "Service ${svc_name} not found in namespace ${NAMESPACE}"
      continue
    fi

    # Skip headless services (clusterIP: None) - they cannot be NodePort
    cluster_ip=$(kubectl -n "${NAMESPACE}" get "${svc}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [[ "${cluster_ip}" == "None" ]]; then
      log "Skipping headless service ${svc_name} (cannot be NodePort)"
      continue
    fi

    current_type=$(kubectl -n "${NAMESPACE}" get "${svc}" -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
    if [[ "${current_type}" != "NodePort" ]]; then
      log "Converting service ${svc_name} to NodePort"
      if [[ -n "${NODEPORT}" ]]; then
        if [[ "${NODEPORT}" -lt 30000 ]] || [[ "${NODEPORT}" -gt 32767 ]]; then
          die "NodePort must be between 30000-32767, got: ${NODEPORT}"
        fi
        log "Setting fixed NodePort: ${NODEPORT}"
        PATCH_JSON="[
          {\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},
          {\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${NODEPORT}}
        ]"
      else
        PATCH_JSON="[
          {\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"}
        ]"
      fi
      kubectl -n "${NAMESPACE}" patch "${svc}" --type='json' -p="${PATCH_JSON}" 2>/dev/null || \
        warn "Failed to patch service ${svc_name} to NodePort"
    else
      log "Service ${svc_name} is already NodePort"
      if [[ -n "${NODEPORT}" ]]; then
        current_nodeport=$(kubectl -n "${NAMESPACE}" get "${svc}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
        if [[ -n "${current_nodeport}" ]] && [[ "${current_nodeport}" != "${NODEPORT}" ]]; then
          log "Updating NodePort from ${current_nodeport} to ${NODEPORT} for ${svc_name}"
          kubectl -n "${NAMESPACE}" patch "${svc}" --type='json' \
            -p="[{\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${NODEPORT}}]" \
            2>/dev/null || warn "Failed to update NodePort for ${svc_name}"
        fi
      fi
    fi
  done
fi

# -----------------------------
# Print Quick Test Snippet (always)
# -----------------------------
print_quick_test() {
  local ns="$1" model="$2"
  local node_ip svc svc_port nodeport

  node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo 'localhost')"

  if [[ -n "${CURRENT_SERVICE_NAMES:-}" ]]; then
    for s in ${CURRENT_SERVICE_NAMES}; do
      if [[ "${s}" == *frontend* ]] && [[ "${s}" != *-d ]] && [[ "${s}" != *-p ]]; then
        svc="${s}"
        break
      fi
    done
    if [[ -z "${svc:-}" ]]; then
      svc="$(printf '%s\n' ${CURRENT_SERVICE_NAMES} | awk 'NR==1{print; exit}')"
    fi
  else
    svc="$(kubectl -n "${ns}" get svc --no-headers 2>/dev/null | awk '/frontend/ {print $1; exit}')"
    if [[ -z "${svc:-}" ]]; then
      svc="$(kubectl -n "${ns}" get svc --no-headers 2>/dev/null | awk 'NR==1{print $1; exit}')"
    fi
  fi

  if [[ -n "${svc:-}" ]]; then
    svc_port="$(kubectl -n "${ns}" get svc "${svc}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo '8000')"
    nodeport="$(kubectl -n "${ns}" get svc "${svc}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo '')"
  fi

  echo ""
  echo "=== Quick test (copy/paste) ==="
  if [[ -n "${svc:-}" && -n "${nodeport:-}" ]]; then
    echo "export DYNAMO_BASE_URL=http://${node_ip}:${nodeport}"
  elif [[ -n "${svc:-}" ]]; then
    echo "# NodePort not set for ${svc}. Check service type:"
    echo "#   kubectl -n ${ns} get svc ${svc} -o wide"
    echo "export DYNAMO_BASE_URL=http://<NODE_IP>:<NODE_PORT>"
  else
    echo "export DYNAMO_BASE_URL=http://<NODE_IP>:<NODE_PORT>"
    echo "# Discover a service:"
    echo "#   kubectl -n ${ns} get svc"
  fi
  echo "curl -sS \"\$DYNAMO_BASE_URL/v1/models\" | jq ."
  echo "curl -sS \"\$DYNAMO_BASE_URL/v1/chat/completions\" \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -H 'Authorization: Bearer dummy' \\"
  echo "  -d '{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}],\"max_tokens\":64}' | jq -r '.choices[0].message.content'"
  echo ""
}

# -----------------------------
# Wait for Deployment (if requested)
# -----------------------------
if [[ "${NO_WAIT}" != "true" ]]; then
  log "Waiting for deployment to be ready..."
  
  # Wait for frontend pod (common in agg/disagg deployments)
  FRONTEND_PATTERN=".*-frontend-.*"
  HAS_FRONTEND="false"
  if [[ -n "${MANIFEST_RESOURCE_NAMES}" ]]; then
    for res in ${MANIFEST_RESOURCE_NAMES}; do
      if [[ "${res}" == *frontend ]]; then
        FRONTEND_PATTERN="^${res}-"
        HAS_FRONTEND="true"
        break
      fi
    done
  fi
  if [[ "${HAS_FRONTEND}" == "true" ]] || kubectl -n "${NAMESPACE}" get pods --no-headers 2>/dev/null | grep -q "frontend"; then
    log "Waiting for frontend pod to be ready"
    wait_pod_ready_by_grep "${NAMESPACE}" "${FRONTEND_PATTERN}" "${PODS_TIMEOUT}" || \
      warn "Frontend pod did not become ready within timeout"
  fi
  
  # Wait for worker pods
  WORKER_PATTERN=".*worker.*"
  HAS_WORKER="false"
  if [[ -n "${MANIFEST_RESOURCE_NAMES}" ]]; then
    WORKER_PATTERN=""
    for res in ${MANIFEST_RESOURCE_NAMES}; do
      if [[ "${res}" == *worker* ]]; then
        HAS_WORKER="true"
        if [[ -z "${WORKER_PATTERN}" ]]; then
          WORKER_PATTERN="^${res}-"
        else
          WORKER_PATTERN="${WORKER_PATTERN}|^${res}-"
        fi
      fi
    done
    if [[ -z "${WORKER_PATTERN}" ]]; then
      WORKER_PATTERN=".*worker.*"
    fi
  fi
  if [[ "${HAS_WORKER}" == "true" ]] || kubectl -n "${NAMESPACE}" get pods --no-headers 2>/dev/null | grep -q "worker"; then
    log "Waiting for worker pods to be ready"
    wait_pod_ready_by_grep "${NAMESPACE}" "${WORKER_PATTERN}" "${PODS_TIMEOUT}" || \
      warn "Worker pods did not become ready within timeout"
  fi
  
  # Wait for service endpoints
  FRONTEND_SVC=""
  if [[ -n "${CURRENT_SERVICE_NAMES}" ]]; then
    for svc in ${CURRENT_SERVICE_NAMES}; do
      if [[ "${svc}" == *frontend* ]] && [[ "${svc}" != *-d ]] && [[ "${svc}" != *-p ]]; then
        FRONTEND_SVC="${svc}"
        break
      fi
    done
  else
    if kubectl -n "${NAMESPACE}" get svc --no-headers 2>/dev/null | grep -q "frontend"; then
      FRONTEND_SVC="$(kubectl -n "${NAMESPACE}" get svc --no-headers 2>/dev/null | grep frontend | awk '{print $1}' | head -n1)"
    fi
  fi
  if [[ -n "${FRONTEND_SVC}" ]]; then
    log "Waiting for service endpoints: ${FRONTEND_SVC}"
    wait_endpoints "${NAMESPACE}" "${FRONTEND_SVC}" "${ENDPOINTS_TIMEOUT}" || \
      warn "Service endpoints not ready within timeout"
  fi
  
  log "Current deployment status:"
  PODS_LIST="$(kubectl -n "${NAMESPACE}" get pods -o wide --no-headers 2>/dev/null || true)"
  if [[ -n "${PODS_LIST}" ]]; then
    if [[ -n "${MANIFEST_RESOURCE_NAMES}" ]]; then
      echo "Pods (current deployment):"
      echo "${PODS_LIST}" | awk -v names="${MANIFEST_RESOURCE_NAMES}" '
        BEGIN{
          split(names, a, " ");
          for (i in a) if (a[i] != "") pats[a[i]] = 1;
        }
        {
          for (p in pats) {
            if ($1 ~ ("^" p)) { print; next }
          }
        }'
    else
      echo "Pods:"
      echo "${PODS_LIST}"
    fi
  fi

  if [[ -n "${CURRENT_SERVICE_NAMES}" ]]; then
    echo "Services (current deployment):"
    for svc in ${CURRENT_SERVICE_NAMES}; do
      kubectl -n "${NAMESPACE}" get svc "${svc}" -o wide 2>/dev/null || true
    done
  else
    kubectl -n "${NAMESPACE}" get svc 2>/dev/null || true
  fi
  
  # Print access information for all NodePort services
  NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo 'localhost')"
  
  echo -e "\n==> Deployment Complete ✅"
  echo ""
  
  # Only show services from this manifest (frontend-only)
  USER_SERVICES=""
  if [[ -n "${CURRENT_SERVICE_NAMES}" ]]; then
    for svc in ${CURRENT_SERVICE_NAMES}; do
      svc_type="$(kubectl -n "${NAMESPACE}" get svc "${svc}" -o jsonpath='{.spec.type}' 2>/dev/null || echo '')"
      if [[ "${svc_type}" == "NodePort" ]] && [[ "${svc}" == *frontend* ]] && [[ "${svc}" != *-d ]] && [[ "${svc}" != *-p ]]; then
        USER_SERVICES="${USER_SERVICES}${svc}\n"
      fi
    done
  fi
  
  echo ""
else
  log "Skipping wait (--no-wait specified)"
  PODS_LIST="$(kubectl -n "${NAMESPACE}" get pods -o wide --no-headers 2>/dev/null || true)"
  if [[ -n "${PODS_LIST}" ]]; then
    if [[ -n "${MANIFEST_RESOURCE_NAMES}" ]]; then
      echo "Pods (current deployment):"
      echo "${PODS_LIST}" | awk -v names="${MANIFEST_RESOURCE_NAMES}" '
        BEGIN{
          split(names, a, " ");
          for (i in a) if (a[i] != "") pats[a[i]] = 1;
        }
        {
          for (p in pats) {
            if ($1 ~ ("^" p)) { print; next }
          }
        }'
    else
      echo "Pods:"
      echo "${PODS_LIST}"
    fi
  fi
fi

# Ensure HF cache env vars are set for current deployments
if [[ -n "${CURRENT_DEPLOYMENTS}" && -n "${HF_TOKEN}" ]]; then
  log "Configuring HuggingFace token env in current deployments"
  for dep in ${CURRENT_DEPLOYMENTS}; do
    kubectl -n "${NAMESPACE}" set env "${dep}" --from=secret/hf-token-secret \
      >/dev/null 2>&1 || warn "Failed to set HF token env for ${dep}"
  done
fi

print_quick_test "${NAMESPACE}" "${MODEL}"

log "Deployment script completed"
