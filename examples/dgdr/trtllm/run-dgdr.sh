#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-dynamo-system}"
CONFIGMAP_NAME="${CONFIGMAP_NAME:-qwen-config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISAGG_FILE="${DISAGG_FILE:-$SCRIPT_DIR/disagg.yaml}"
DGDR_FILE="${DGDR_FILE:-$SCRIPT_DIR/dgdr.yaml}"

log() { echo -e "\n==> $*\n"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

need kubectl

if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  log "Creating namespace $NAMESPACE"
  kubectl create namespace "$NAMESPACE"
fi

log "Creating/Updating ConfigMap $CONFIGMAP_NAME from $DISAGG_FILE"
kubectl create configmap "$CONFIGMAP_NAME" \
  --from-file=disagg.yaml="$DISAGG_FILE" \
  --namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Applying DGDR manifest $DGDR_FILE"
kubectl apply -n "$NAMESPACE" -f "$DGDR_FILE"

log "Expose frontend via NodePort (fixed port)"
export FRONTEND_NODEPORT="${FRONTEND_NODEPORT:-30081}"
FRONTEND_SVC="$(kubectl -n "$NAMESPACE" get svc --no-headers | awk '/frontend/ {print $1; exit}')"
export FRONTEND_SVC
if [[ -n "${FRONTEND_SVC}" ]]; then
  kubectl patch svc "$FRONTEND_SVC" -n "$NAMESPACE" --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},{\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${FRONTEND_NODEPORT}}]"
else
  log "Frontend service not found yet. Re-run the NodePort snippet later."
fi

NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "localhost")"
export NODE_IP
log "Frontend URL: http://${NODE_IP}:${FRONTEND_NODEPORT}"

log "Quick query snippet:"
cat <<EOF
curl -sS "http://${NODE_IP}:${FRONTEND_NODEPORT}/v1/chat/completions" \\
  -H 'Content-Type: application/json' \\
  -H 'Authorization: Bearer dummy' \\
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Hello!"}],"max_tokens":64}' | jq -r '.choices[0].message.content'
EOF

log "Done. Inspect with: kubectl -n $NAMESPACE get dynamographdeploymentrequests"
