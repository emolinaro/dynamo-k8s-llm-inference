#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Deploy a model using a specific Dynamo manifest file (no manifest patching)
#
# This script:
#  1) Validates and applies the provided manifest file
#  2) Creates the namespace (if needed)
#  3) Optionally creates an hf-token secret (dummy if not provided)
#  4) Converts services to NodePort for external access
#  5) Waits for deployment to be ready (optional)
#
# Usage:
#   ./deploy-incluster.sh --manifest /path/to/manifest.yaml
#
# Options:
#   --manifest FILE      Manifest file to apply [required]
#   --namespace NS       Kubernetes namespace [default: dynamo-system]
#   --model MODEL        Model name used for the quick test snippet [optional]
#   --hf-token TOKEN     HuggingFace token for private/gated models [optional]
#   --nodeport PORT      Fixed NodePort (30000-32767) or auto-assign if not set [optional]
#   --no-wait            Don't wait for pods to be ready
###############################################################################

# -----------------------------
# Default Configuration
# -----------------------------
NAMESPACE="${NAMESPACE:-dynamo-system}"
MANIFEST_FILE="${MANIFEST_FILE:-}"
MODEL="${MODEL:-}"
HF_TOKEN="${HF_TOKEN:-}"
NODEPORT="${NODEPORT:-}"
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
  --manifest FILE      Manifest file to apply

Optional:
  --namespace NS       Kubernetes namespace [default: dynamo-system]
  --model MODEL        Model name used for the quick test snippet
  --hf-token TOKEN     HuggingFace token for private/gated models
  --nodeport PORT      Fixed NodePort (30000-32767) or auto-assign if not set
  --no-wait            Don't wait for pods to be ready

Examples:
  $0 --manifest ./manifests/vllm-agg.yaml
  $0 --manifest /tmp/agg.yaml --namespace my-ns --nodeport 30080
  $0 --manifest ./custom.yaml --model Qwen/Qwen3-0.6B --hf-token \$HF_TOKEN
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
    --manifest)
      MANIFEST_FILE="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
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
[[ -n "${MANIFEST_FILE}" ]] || die "--manifest is required\n$(usage)"
[[ -f "${MANIFEST_FILE}" ]] || die "Manifest file not found: ${MANIFEST_FILE}"

MANIFEST="${MANIFEST_FILE}"

# -----------------------------
# Pre-flight
# -----------------------------
log "Pre-flight checks"
need kubectl

kubectl get nodes >/dev/null 2>&1 || die "Cannot connect to Kubernetes cluster"

log "Verify GPUs are allocatable"
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable.nvidia\\.com/gpu || true
GPU_TOTAL="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
  | awk 'BEGIN{s=0} {if($1!=""){s+=$1}} END{print s}')"
[[ "${GPU_TOTAL}" -gt 0 ]] || warn "No GPUs allocatable (nvidia.com/gpu missing/0)"

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
# Apply Manifest
# -----------------------------
log "Applying manifest to namespace ${NAMESPACE}"
kubectl apply -n "${NAMESPACE}" -f "${MANIFEST}"

# Extract resource and service names from the manifest we just applied
MANIFEST_RESOURCE_NAMES="$(grep -E "^[[:space:]]*name:[[:space:]]+" "${MANIFEST}" | \
  sed -E "s|^[[:space:]]*name:[[:space:]]+([^[:space:]#]+).*|\\1|" | sort -u)"

MANIFEST_SERVICE_NAMES="$(awk '
  /^[[:space:]]*kind:[[:space:]]*Service[[:space:]]*$/ {in_svc=1; next}
  in_svc && /^[[:space:]]*name:[[:space:]]*/ {
    line=$0
    sub(/^[[:space:]]*name:[[:space:]]*/,"",line)
    sub(/[[:space:]#].*$/,"",line)
    if (line != "") print line
    in_svc=0
  }
' "${MANIFEST}" | sort -u)"

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
' "${MANIFEST}")"

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

# -----------------------------
# Convert Services to NodePort
# -----------------------------
log "Converting services from this deployment to NodePort for external access"

# If no services were found initially, try to find them again (they might have been created by CRD controller)
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
      warn "Timed out waiting for services. Services may be created later by the controller."
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

  if [[ -z "${model}" ]]; then
    model="<MODEL_FROM_MANIFEST>"
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
  if [[ "${model}" == "<MODEL_FROM_MANIFEST>" ]]; then
    echo "# Replace <MODEL_FROM_MANIFEST> with the model name from your manifest"
  fi
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
