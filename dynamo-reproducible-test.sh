#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Dynamo Platform Reproducible GPU Smoke Test
#
# Validates:
#  - GPUs are allocatable in K8s
#  - vLLM agg example deploys successfully
#  - /v1/models becomes non-empty
#  - /v1/chat/completions returns valid structure + non-empty assistant content
#
# Notes:
#  - Does NOT force a specific model; whatever the deployment serves is accepted.
#  - Warns (does not fail) if content contains <think> reasoning.
###############################################################################

# -----------------------------
# Configuration (override via env vars)
# -----------------------------
NAMESPACE="${NAMESPACE:-dynamo-system}"

DYNAMO_REPO_URL="${DYNAMO_REPO_URL:-https://github.com/ai-dynamo/dynamo.git}"
DYNAMO_REPO_DIR="${DYNAMO_REPO_DIR:-dynamo}"
AGG_MANIFEST_REL="${AGG_MANIFEST_REL:-examples/backends/vllm/deploy/agg.yaml}"

VLLM_RUNTIME_TAG="${VLLM_RUNTIME_TAG:-0.6.1}"

FRONTEND_SVC="${FRONTEND_SVC:-vllm-agg-frontend}"
LOCAL_PORT="${LOCAL_PORT:-8000}"
REMOTE_PORT="${REMOTE_PORT:-8000}"

PODS_TIMEOUT="${PODS_TIMEOUT:-1200}"
ENDPOINTS_TIMEOUT="${ENDPOINTS_TIMEOUT:-300}"
MODELS_TIMEOUT="${MODELS_TIMEOUT:-600}"

CLEANUP_ON_EXIT="${CLEANUP_ON_EXIT:-false}"

# -----------------------------
# Helpers
# -----------------------------
log() { echo -e "\n==> $*\n"; }
warn() { echo -e "WARN: $*\n" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
have() { command -v "$1" >/dev/null 2>&1; }

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

extract_model_id() {
  local json="$1"
  if have jq; then
    echo "$json" | jq -r '.data[0].id // empty' 2>/dev/null || true
  else
    echo "$json" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
  fi
}

# -----------------------------
# Pre-flight
# -----------------------------
log "Pre-flight"
need kubectl
need git
need curl
if ! have jq; then
  warn "jq not found. Install for nicer output: sudo apt-get install -y jq"
fi

kubectl get nodes >/dev/null

log "Verify GPUs are allocatable"
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable.nvidia\\.com/gpu
GPU_TOTAL="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
  | awk 'BEGIN{s=0} {if($1!=""){s+=$1}} END{print s}')"
[[ "${GPU_TOTAL}" -gt 0 ]] || die "No GPUs allocatable (nvidia.com/gpu missing/0)"

# -----------------------------
# Repo and manifest
# -----------------------------
log "Ensure Dynamo repo exists (examples)"
if [[ ! -d "${DYNAMO_REPO_DIR}/.git" ]]; then
  git clone "${DYNAMO_REPO_URL}" "${DYNAMO_REPO_DIR}"
fi

AGG_MANIFEST="${DYNAMO_REPO_DIR}/${AGG_MANIFEST_REL}"
[[ -f "${AGG_MANIFEST}" ]] || die "agg.yaml not found: ${AGG_MANIFEST}"

# -----------------------------
# Required secret for example
# -----------------------------
log "Ensure hf-token-secret exists (dummy value; example references it)"
kubectl -n "${NAMESPACE}" create secret generic hf-token-secret \
  --from-literal=token=dummy \
  --dry-run=client -o yaml | kubectl apply -f -

# -----------------------------
# Apply example (patch runtime tag)
# -----------------------------
log "Apply vLLM agg example (patch :my-tag -> :${VLLM_RUNTIME_TAG})"
PATCHED_AGG="$(mktemp)"
sed "s/:my-tag/:${VLLM_RUNTIME_TAG}/g" "${AGG_MANIFEST}" > "${PATCHED_AGG}"
grep -q ":${VLLM_RUNTIME_TAG}" "${PATCHED_AGG}" || die "Tag patch failed"

kubectl apply -n "${NAMESPACE}" -f "${PATCHED_AGG}"

cleanup_workload() {
  if [[ "${CLEANUP_ON_EXIT}" == "true" ]]; then
    log "Cleanup enabled: deleting vLLM example resources"
    kubectl delete -n "${NAMESPACE}" -f "${PATCHED_AGG}" >/dev/null 2>&1 || true
  fi
}
trap cleanup_workload EXIT

# -----------------------------
# Wait for pods & endpoints
# -----------------------------
log "Wait for frontend pod Ready"
wait_pod_ready_by_grep "${NAMESPACE}" '^vllm-agg-frontend-' "${PODS_TIMEOUT}" \
  || die "Frontend did not become Ready"

log "Wait for decode worker pod Ready"
wait_pod_ready_by_grep "${NAMESPACE}" '^vllm-agg-vllmdecodeworker-' "${PODS_TIMEOUT}" \
  || die "Decode worker did not become Ready"

log "Wait for service endpoints"
wait_endpoints "${NAMESPACE}" "${FRONTEND_SVC}" "${ENDPOINTS_TIMEOUT}" \
  || die "Frontend service has no endpoints"
wait_endpoints "${NAMESPACE}" "vllm-agg-vllmdecodeworker" "${ENDPOINTS_TIMEOUT}" \
  || die "Decode worker service has no endpoints"

kubectl -n "${NAMESPACE}" get pods -o wide | grep -E 'vllm-agg|vllmdecodeworker' || true

# -----------------------------
# Port-forward and API checks
# -----------------------------
log "Port-forward ${FRONTEND_SVC}"
PF_PID=""
cleanup_pf() { [[ -n "${PF_PID}" ]] && kill "${PF_PID}" >/dev/null 2>&1 || true; }
trap cleanup_pf EXIT

kubectl -n "${NAMESPACE}" port-forward "svc/${FRONTEND_SVC}" "${LOCAL_PORT}:${REMOTE_PORT}" >/dev/null 2>&1 &
PF_PID="$!"
sleep 2

log "Test 1: /v1/models becomes non-empty"
start="$(date +%s)"
MODEL_ID=""
MODELS_JSON=""
while true; do
  MODELS_JSON="$(curl -sS "http://127.0.0.1:${LOCAL_PORT}/v1/models" || true)"
  MODEL_ID="$(extract_model_id "${MODELS_JSON}")"
  [[ -n "${MODEL_ID}" ]] && break

  now="$(date +%s)"
  if (( now - start > MODELS_TIMEOUT )); then
    echo "---- /v1/models still empty ----" >&2
    echo "${MODELS_JSON}" >&2
    WPOD="$(kubectl -n "${NAMESPACE}" get pod -o name | grep vllmdecodeworker | head -n1 | cut -d/ -f2 || true)"
    [[ -n "${WPOD}" ]] && kubectl -n "${NAMESPACE}" logs "${WPOD}" --tail=200 || true
    die "/v1/models never became non-empty"
  fi
  sleep 5
done

log "/v1/models returned model id: ${MODEL_ID}"
if have jq; then echo "${MODELS_JSON}" | jq .; else echo "${MODELS_JSON}"; fi

log "Test 2: /v1/chat/completions returns valid structure + non-empty content"
CHAT_PAYLOAD="$(cat <<EOF
{
  "model": "${MODEL_ID}",
  "messages": [{"role":"user","content":"Reply with a short greeting."}],
  "temperature": 0.0,
  "max_tokens": 256
}
EOF
)"

CHAT_JSON="$(curl -sS "http://127.0.0.1:${LOCAL_PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "${CHAT_PAYLOAD}")"

if have jq; then echo "${CHAT_JSON}" | jq .; else echo "${CHAT_JSON}"; fi

# Hard assertions: API contract
echo "${CHAT_JSON}" | grep -q '"choices"' || die "Chat test failed: no choices"

if have jq; then
  CONTENT="$(echo "${CHAT_JSON}" | jq -r '.choices[0].message.content // empty')"
  FINISH="$(echo "${CHAT_JSON}" | jq -r '.choices[0].finish_reason // empty')"
else
  CONTENT="$(echo "${CHAT_JSON}" | sed -n 's/.*"content"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -n1)"
  FINISH="$(echo "${CHAT_JSON}" | sed -n 's/.*"finish_reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
fi

[[ -n "${CONTENT}" ]] || die "Chat test failed: empty assistant content"

# Soft warnings (do not fail)
THINK_WARN=0
if echo "${CONTENT}" | grep -q '<think>'; then
  THINK_WARN=1
  warn "Model '${MODEL_ID}' returned <think> reasoning (model-specific; smoke test still passed)."
fi
if [[ "${FINISH}" == "length" ]]; then
  warn "finish_reason=length (truncated). Increase max_tokens if you care about complete text."
fi

echo "SUMMARY: models_ok=1 chat_ok=1 model=${MODEL_ID} think_warning=${THINK_WARN} finish_reason=${FINISH}"
log "SUCCESS ✅ Dynamo reproducible GPU test passed"
