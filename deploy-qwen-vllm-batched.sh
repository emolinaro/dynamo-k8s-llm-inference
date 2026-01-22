#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Deploy a batched inference server (vLLM) for Qwen/Qwen3-0.6B on Kubernetes
#
# CORRECTION IMPLEMENTED:
#  - DO NOT override `command:` to ["python", ...]
#    Your cluster showed: exec: "python": executable file not found in $PATH
#    for image vllm/vllm-openai:latest.
#  - Instead, rely on the image ENTRYPOINT and only pass `args:`.
#
# NODEPORT UPDATE:
#  - The Service is now exposed as type: NodePort (instead of ClusterIP).
#  - The script prints the Node IP + NodePort so you can access the server
#    without kubectl port-forward.
#
# What this script does:
#  1) Creates/updates a namespace
#  2) Deploys a vLLM OpenAI-compatible server on 1 GPU with batching knobs
#  3) Adds /dev/shm (shared memory) to avoid common PyTorch/vLLM issues
#  4) Exposes it via a NodePort service
#  5) Waits for rollout and prints the access URL
#
# Usage:
#  chmod +x deploy-qwen-vllm-batched.sh
#  ./deploy-qwen-vllm-batched.sh
###############################################################################

# -----------------------------
# Config (override via env vars)
# -----------------------------
NS="${NS:-qwen-infer}"
NAME="${NAME:-qwen-vllm}"
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"

# vLLM OpenAI-compatible image
# NOTE: we do NOT call "python" explicitly; we rely on the image entrypoint.
IMAGE="${IMAGE:-vllm/vllm-openai:latest}"

PORT="${PORT:-8000}"

# Optional: pin a stable NodePort (must be within 30000-32767 and unused).
# If left empty, Kubernetes will auto-assign a NodePort.
NODEPORT="${NODEPORT:-}"

# Batching / concurrency knobs
MAX_NUM_SEQS="${MAX_NUM_SEQS:-128}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"
ENABLE_CHUNKED_PREFILL="${ENABLE_CHUNKED_PREFILL:-true}"

# GPU resources
GPUS_PER_POD="${GPUS_PER_POD:-1}"

# Cache volume (model downloads)
CACHE_SIZE="${CACHE_SIZE:-80Gi}"

# Shared memory for PyTorch/vLLM stability
DSHM_SIZE="${DSHM_SIZE:-8Gi}"

# -----------------------------
# Pre-flight
# -----------------------------
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }

echo -e "\n==> Verifying GPUs are allocatable..."
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable.nvidia\\.com/gpu

# -----------------------------
# Apply manifest (single, clean spec)
# -----------------------------
echo -e "\n==> Deploying ${NAME} in namespace ${NS} (model: ${MODEL})"
kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${NAME}
  template:
    metadata:
      labels:
        app: ${NAME}
    spec:
      containers:
        - name: vllm
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: ${PORT}

          # IMPORTANT:
          # - We intentionally do NOT set "command:" here.
          # - The vllm/vllm-openai image entrypoint is responsible for starting
          #   the server, and it may not have "python" on PATH.
          args:
            - --model
            - ${MODEL}
            - --host
            - 0.0.0.0
            - --port
            - "${PORT}"
            - --max-num-seqs
            - "${MAX_NUM_SEQS}"
            - --max-num-batched-tokens
            - "${MAX_NUM_BATCHED_TOKENS}"
YAML

# Add chunked prefill flag only if enabled
if [[ "${ENABLE_CHUNKED_PREFILL}" == "true" ]]; then
  kubectl -n "${NS}" patch deploy "${NAME}" --type='json' -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-chunked-prefill"}
  ]' >/dev/null
fi

# Patch in GPU resources, cache volume, and /dev/shm
# Why patch instead of inline YAML:
# - Keeps the main manifest readable.
kubectl -n "${NS}" patch deploy "${NAME}" --type='json' -p="[
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/resources\",\"value\":{
    \"requests\":{\"nvidia.com/gpu\": ${GPUS_PER_POD}},
    \"limits\":{\"nvidia.com/gpu\": ${GPUS_PER_POD}}
  }},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":[
    {\"name\":\"HF_HOME\",\"value\":\"/cache/hf\"},
    {\"name\":\"TRANSFORMERS_CACHE\",\"value\":\"/cache/hf\"}
  ]},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/volumes\",\"value\":[
    {\"name\":\"cache\",\"emptyDir\":{\"sizeLimit\":\"${CACHE_SIZE}\"}},
    {\"name\":\"dshm\",\"emptyDir\":{\"medium\":\"Memory\",\"sizeLimit\":\"${DSHM_SIZE}\"}}
  ]},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/volumeMounts\",\"value\":[
    {\"name\":\"cache\",\"mountPath\":\"/cache\"},
    {\"name\":\"dshm\",\"mountPath\":\"/dev/shm\"}
  ]}
]" >/dev/null

echo -e "\n==> Creating/Updating Service (NodePort) ..."

# If NODEPORT is set, create a fixed NodePort, otherwise let Kubernetes assign one.
if [[ -n "${NODEPORT}" ]]; then
  kubectl -n "${NS}" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ${NAME}
  namespace: ${NS}
spec:
  selector:
    app: ${NAME}
  ports:
    - name: http
      port: ${PORT}
      targetPort: ${PORT}
      nodePort: ${NODEPORT}
  type: NodePort
YAML
else
  kubectl -n "${NS}" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ${NAME}
  namespace: ${NS}
spec:
  selector:
    app: ${NAME}
  ports:
    - name: http
      port: ${PORT}
      targetPort: ${PORT}
  type: NodePort
YAML
fi

echo -e "\n==> Waiting for rollout..."
kubectl -n "${NS}" rollout status deploy/"${NAME}" --timeout=30m

echo -e "\n==> Current pods:"
kubectl -n "${NS}" get pods -o wide

# -----------------------------
# Print access URL
# -----------------------------
NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
SVC_NODEPORT="$(kubectl -n "${NS}" get svc "${NAME}" -o jsonpath='{.spec.ports[0].nodePort}')"

echo -e "\n==> Done ✅"
echo "Access from any host that can reach the node:"
echo "  http://${NODE_IP}:${SVC_NODEPORT}"
echo
echo "Test:"
echo "  curl -sS http://${NODE_IP}:${SVC_NODEPORT}/v1/models | jq ."
echo "  curl -sS http://${NODE_IP}:${SVC_NODEPORT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' -H 'Authorization: Bearer dummy' \\"
echo "    -d '{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":64}' | jq -r '.choices[0].message.content'"
