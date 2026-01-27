# Dynamo K8s LLM Inference

A collection of scripts for deploying and testing Large Language Model (LLM) inference on Kubernetes using NVIDIA Dynamo Platform and vLLM.

## Overview

This repository provides end-to-end automation for:
- Setting up a single-node Kubernetes cluster with Cilium CNI
- Installing NVIDIA Dynamo Platform for GPU orchestration
- Deploying vLLM-based inference servers with batching support
- Testing and interacting with deployed models

## Prerequisites

- Ubuntu 24.04 (or compatible Linux distribution)
- Root/sudo access
- NVIDIA GPU(s) with appropriate drivers
- Internet connectivity for downloading images and packages

## Quick Start

You can use the Makefile shortcuts or run the scripts directly.

### Option A: Makefile (recommended)

```bash
make install
```

Override any script env vars inline:

```bash
RELEASE_VERSION=0.8.1 make dynamo
K8S_REPO_MINOR=v1.35 POD_CIDR=10.1.0.0/16 make k8s
```

### Option B: Scripts

### 1. Set Up Kubernetes Cluster

First, initialize a single-node Kubernetes cluster:

```bash
sudo ./k8s-single-node-cilium.sh
```

This script will:
- Install containerd, kubeadm, kubectl, and Helm
- Initialize a single-node Kubernetes cluster
- Install Cilium CNI with optional Hubble support
- Configure kubectl for your user

**Note:** After running this script, you may need to log out and back in, or run:
```bash
export KUBECONFIG=$HOME/.kube/config
```

### 2. Install Dynamo Platform

Install NVIDIA Dynamo Platform and GPU Operator:

```bash
export RELEASE_VERSION=0.8.1  # Adjust to match your Dynamo version
./install-dynamo-1node.sh
```

This script will:
- Install a default StorageClass (local-path-provisioner) for single-node clusters
- Install Dynamo CRDs and Platform components
- Install NVIDIA GPU Operator to enable GPU scheduling
- Verify that GPUs are allocatable in Kubernetes

### 3. Deploy vLLM Inference Server

Deploy a batched vLLM inference server:

```bash
./deploy-qwen-vllm-batched.sh
```

This will:
- Deploy vLLM with OpenAI-compatible API
- Configure batching parameters for optimal throughput
- Expose the service via NodePort
- Print the access URL for the inference server

**Configuration options** (via environment variables):
- `MODEL`: Model to deploy (default: `Qwen/Qwen3-0.6B`)
- `GPUS_PER_POD`: Number of GPUs per pod (default: `1`)
- `MAX_NUM_SEQS`: Maximum concurrent sequences (default: `128`)
- `MAX_NUM_BATCHED_TOKENS`: Maximum batched tokens (default: `8192`)
- `NODEPORT`: Fixed NodePort (optional, 30000-32767)

### 4. Test the Deployment

Run the reproducible GPU smoke test:

```bash
./dynamo-reproducible-test.sh
```

This validates:
- GPU allocatability in Kubernetes
- vLLM deployment success
- API endpoints (`/v1/models`, `/v1/chat/completions`)
- Response structure and content

### 5. Chat with the Model

Use the interactive chat script:

```bash
./chat.sh
```

This provides an interactive interface that:
- Connects to the deployed inference server
- Handles conversation history
- Extracts final answers from model responses (handles `<think>` tags)
- Provides auto-repair for malformed responses

## Scripts Overview

### `k8s-single-node-cilium.sh`
Sets up a single-node Kubernetes cluster on Ubuntu 24.04.

**Configuration:**
- `K8S_REPO_MINOR`: Kubernetes version (default: `v1.35`)
- `CLUSTER_NAME`: Cluster name (default: `k8s-single`)
- `POD_CIDR`: Pod network CIDR (default: `10.0.0.0/16`)
- `ENABLE_HUBBLE`: Enable Hubble observability (default: `true`)
- `HELM_VERSION`: Helm version to install (default: `v4.1.0`)
- `INSTALL_HELM`: Install Helm (default: `true`)
- `INSTALL_PROMETHEUS_STACK`: Install kube-prometheus-stack (default: `true`)

### `install-dynamo-1node.sh`
Installs NVIDIA Dynamo Platform on a 1-node Kubernetes cluster.

**Configuration:**
- `NAMESPACE`: Dynamo namespace (default: `dynamo-system`)
- `RELEASE_VERSION`: Dynamo release version (default: `0.8.1`)
- `NAMESPACE_RESTRICTED_OPERATOR`: Enable namespace restriction (default: `false`)
- `GPU_OPERATOR_NS`: GPU Operator namespace (default: `gpu-operator`)

### `deploy-qwen-vllm-batched.sh`
Deploys a vLLM inference server with batching support.

**Configuration:**
- `NS`: Kubernetes namespace (default: `qwen-infer`)
- `NAME`: Deployment name (default: `qwen-vllm`)
- `MODEL`: HuggingFace model identifier (default: `Qwen/Qwen3-0.6B`)
- `IMAGE`: vLLM container image (default: `vllm/vllm-openai:latest`)
- `GPUS_PER_POD`: Number of GPUs (default: `1`)
- `MAX_NUM_SEQS`: Max concurrent sequences (default: `128`)
- `MAX_NUM_BATCHED_TOKENS`: Max batched tokens (default: `8192`)

### `dynamo-reproducible-test.sh`
Runs a reproducible GPU smoke test for Dynamo Platform.

**Configuration:**
- `NAMESPACE`: Dynamo namespace (default: `dynamo-system`)
- `VLLM_RUNTIME_TAG`: vLLM runtime tag (default: `0.6.1`)
- `CLEANUP_ON_EXIT`: Clean up resources on exit (default: `false`)

### `chat.sh`
Interactive chat interface for the deployed inference server.

**Configuration:**
- `API_URL`: API endpoint (default: `http://127.0.0.1:8000/v1/chat/completions`)
- `MODEL`: Model identifier (default: `Qwen/Qwen3-0.6B`)

## Accessing the Inference Server

After deployment, the inference server is accessible via NodePort. The deployment script prints the access URL, typically:

```
http://<NODE_IP>:<NODEPORT>
```

You can also use port-forwarding:

```bash
kubectl port-forward -n qwen-infer svc/qwen-vllm 8000:8000
```

Then access it at `http://127.0.0.1:8000`.

### Example API Calls

**List models:**
```bash
curl http://<NODE_IP>:<NODEPORT>/v1/models | jq .
```

**Chat completion:**
```bash
curl http://<NODE_IP>:<NODEPORT>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer dummy" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 64
  }' | jq -r '.choices[0].message.content'
```

## Troubleshooting

### GPUs Not Visible
If GPUs aren't showing up as allocatable:
```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable.nvidia\\.com/gpu
kubectl get pods -n gpu-operator
kubectl -n gpu-operator logs -l app=nvidia-device-plugin-daemonset
```

### Pods Stuck in Pending
Check resource availability:
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl get events -n <namespace> --sort-by=.lastTimestamp
```

### Storage Issues
Verify StorageClass and PVCs:
```bash
kubectl get storageclass
kubectl get pvc -n dynamo-system
```

### Model Download Issues
Check pod logs for model download progress:
```bash
kubectl logs -n qwen-infer <pod-name> -f
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│              Kubernetes Single-Node Cluster              │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │         NVIDIA Dynamo Platform                   │   │
│  │  - Operator Controller                           │   │
│  │  - etcd (state)                                  │   │
│  │  - NATS (messaging)                              │   │
│  └──────────────────────────────────────────────────┘   │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │         GPU Operator                              │   │
│  │  - Device Plugin                                  │   │
│  │  - Container Toolkit                              │   │
│  └──────────────────────────────────────────────────┘   │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │         vLLM Inference Server                     │   │
│  │  - OpenAI-compatible API                         │   │
│  │  - Batching support                              │   │
│  │  - GPU-accelerated inference                     │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Author

Emiliano Molinaro
