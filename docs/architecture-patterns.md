# Dynamo Architecture Guide

This document provides a coherent overview of Dynamo deployment choices, components, and operational workflows.

## Choosing Your Architecture Pattern

Pick the base configuration that matches your environment and performance goals:

- Development / Testing: start from `agg.yaml`
- Production with Load Balancing: start from `agg_router.yaml`
- High Performance / Disaggregated: start from `disagg_router.yaml`

## Frontend and Worker Components

You can run the Frontend on one machine (e.g., a CPU node) and workers on separate machines (e.g., GPU nodes). The Frontend is a framework-agnostic HTTP entry point that:

- Serves an OpenAI-compatible `/v1/chat/completions` endpoint
- Auto-discovers backend workers (Kubernetes-native service discovery by default)
- Routes requests and handles load balancing
- Validates and preprocesses requests

## Dynamo Operator

Dynamo Operator is a Kubernetes operator that manages the deployment, configuration, and lifecycle of DynamoGraphs. It is installed cluster-wide by default and monitors all namespaces.

To restrict monitoring to a specific namespace (the Helm release namespace by default), enable namespace restriction and optionally set the target namespace:

```sh
--set "dynamo-operator.namespaceRestriction.enabled=true"
--set "dynamo-operator.namespaceRestriction.targetNamespace=dynamo-namespace"  # optional
```

## Custom Resource Definitions (CRDs)

Dynamo provides these Custom Resources:

- `DynamoGraphDeployment` (DGD): deploys complete inference pipelines
- `DynamoComponentDeployment` (DCD): deploys individual components
- `DynamoModel`: manages model lifecycle (e.g., loading LoRA adapters)
- `DynamoGraphDeploymentScalingAdapter`: connects autoscalers to DGD services
- `DynamoGraphDeploymentRequest`: SLA-driven deployment requests

## Service Discovery

Dynamo components (frontends, workers, planner) must discover each other and their capabilities at runtime. Two backends are supported on Kubernetes:

- Kubernetes: recommended for all Kubernetes deployments
- KV Store (etcd): legacy deployments

## Managing Models with DynamoModel

`DynamoModel` represents a model deployed on Dynamo. It enables you to:

- Deploy LoRA adapters on top of running base models
- Track model endpoints and readiness across the cluster
- Manage model lifecycle declaratively via Kubernetes

`DynamoModel` works alongside DGD/DCD resources. DGD/DCD deploy the inference infrastructure (pods, services), while `DynamoModel` handles model-specific operations like loading LoRA adapters.

When you create a `DynamoModel`, the operator:

- Discovers endpoints by matching `modelRef.name` in DGD/DCD
- Creates a Kubernetes Service to track those endpoints
- Loads LoRA adapters on each endpoint (for LoRA models)
- Updates status with readiness information

## Autoscaling and the Planner

Dynamo provides flexible autoscaling through `DynamoGraphDeploymentScalingAdapter` (DGDSA). When you deploy a DGD, the operator automatically creates one adapter per service unless explicitly disabled.

How it works:

- You deploy a DGD with services (Frontend, decode)
- The operator creates one DGDSA per service
- Autoscalers (KEDA, HPA, Planner) target adapters via the `/scale` subresource
- The adapter controller syncs replica changes to the DGD
- The DGD controller reconciles the underlying pods

The Dynamo Planner is an LLM-aware autoscaler that optimizes scaling using inference metrics such as TTFT, ITL, and KV cache utilization.

Use the Planner when:

- You want LLM-optimized autoscaling out of the box
- You need coordinated scaling across prefill/decode services
- You want SLA-driven scaling (e.g., target TTFT < 500ms)

## Architecture Patterns

Dynamo supports deployment patterns across two dimensions:

1. Encoding: Is media encoding handled inline (within prefill) or by a separate Encode Worker?
   - Inline: simpler setup, encoding happens in the prefill worker
   - Separate (EPD): dedicated encode worker transfers embeddings via NIXL, enabling independent scaling

2. Prefill/Decode: Are prefill and decode in the same worker or separate?
   - Aggregated: single worker handles both prefill and decode
   - Disaggregated: separate workers for prefill and decode, with KV cache transfer between them

### EPD - Simple Aggregated

All processing happens within a single worker, the simplest setup.

HTTP Frontend (Rust)
    ↓
Worker (Python)
    ↓ image load + encode + prefill + decode
Response

When to use: quick setup, smaller models, development/testing.

### E/PD - Encode Separate

Encoding happens in a separate worker; prefill and decode share the same engine.

HTTP Frontend (Rust)
    ↓
Processor (Python)
    ↓ tokenizes, extracts media URL
Encode Worker (Python)
    ↓ downloads media, generates embeddings, NIXL transfer
PD Worker (Python)
    ↓ receives embeddings via NIXL, prefill + decode
Response

When to use: offload vision encoding to a separate GPU, scale encode workers independently.

### E/P/D - Full Disaggregation

Full disaggregation with separate workers for encoding, prefill, and decode. Two variants:

- Prefill-first (vLLM)
- Decode-first (SGlang)

Prefill-first:

HTTP Frontend (Rust)
    ↓
Processor (Python)
    ↓ tokenizes, extracts media URL
Encode Worker (Python)
    ↓ downloads media, generates embeddings, NIXL transfer
Prefill Worker (Python)
    ↓ receives embeddings via NIXL, prefill only, KV cache transfer
Decode Worker (Python)
    ↓ decode only, token generation
Response

Decode-first:

HTTP Frontend (Rust)
    ↓
Processor (Python)
    ↓ tokenizes, extracts media URL
Encode Worker (Python)
    ↓ downloads media, generates embeddings, NIXL transfer
Decode Worker (Python)
    ↓ bootstraps prefill worker
Prefill Worker (Python)
    ↓ receives embeddings via NIXL, prefill only, KV cache transfer
Decode Worker (Python)
    ↓ decode only, token generation
Response

When to use: maximum optimization, multi-node deployment, independent scaling of each phase.

### EP/D - Traditional Disaggregated

Encoding is combined with prefill, with decode separate.

HTTP Frontend (Rust)
    ↓
Processor (Python)
    ↓ tokenizes, extracts media URL
Encode+Prefill Worker (Python)
    ↓ downloads media, encodes inline, prefill, KV cache transfer
Decode Worker (Python)
    ↓ decode only, token generation
Response

When to use: models without pre-computed embedding support (e.g., Llama 4) or TRT-LLM disaggregated deployments.

## AIConfigurator

AIConfigurator is a performance optimization tool that determines the best number of prefill and decode workers, parallelism settings, and deployment parameters to meet SLA targets while maximizing throughput.

It helps answer questions like:

- Aggregated vs Disaggregated: which architecture best fits the workload?
- Worker configuration: how many prefill and decode workers to deploy?
- Parallelism settings: which tensor/pipeline parallel configuration to use?
- SLA compliance: how to meet TTFT and TPOT targets?

AIConfigurator provides:

- Configurations that meet SLA requirements
- Ready-to-deploy Dynamo configuration files
- Performance comparisons between deployment strategies
- Up to 1.7x better throughput compared to manual configuration

## SLA-Driven Profiling (DGDR)

A `DynamoGraphDeploymentRequest` (DGDR) is the primary interface for requesting model deployments with specific performance and resource constraints. Think of it as a deployment order where you specify:

- Model to deploy
- SLA targets (TTFT, ITL)
- GPU preferences (optional)
- Backend selection (vllm, sglang, or trtllm)
- Images to use (`profilingConfig.profilerImage`, `deploymentOverrides.workersImage`)

When the operator sees a DGDR, it:

- Discovers available GPU resources in the cluster
- Runs profiling (online or offline) to find optimal configurations
- Generates an optimized DGD configuration
- Deploys the DGD to the cluster

### SLA Configuration

Define performance requirements and workload characteristics:

- ISL/OSL: based on expected traffic patterns
- TTFT: first token latency target (lower requires more GPUs and impacts prefill)
- ITL: token generation latency target (lower requires more GPUs and impacts decode)
- Trade-offs: tighter SLAs require more GPU resources

### Hardware Configuration

Control GPU search space and constraints:

- minNumGpusPerEngine: skip small TP sizes for large models
- maxNumGpusPerEngine: limit search space or work around constraints
- numGpusPerNode: cap GPUs per node for dense models and configure Grove for multi-node MoE
- gpu_type: informational, auto-detected by controller

If hardware constraints are omitted, the controller auto-detects based on model size and cluster resources.

### Sweep Configuration

Control profiling behavior:

- useAiConfigurator: set true for short profiling runs (TensorRT-LLM only)
- prefillInterpolationGranularity: samples for the prefill TTFT curve
- decodeInterpolationGranularity: samples for the decode ITL curve (3D plots take longer)

### Model Cache PVC

Use a pre-populated PVC with model weights to avoid repeated downloads and handle private models. The PVC must exist in the same namespace as the DGDR.

## References

```text
https://docs.nvidia.com/dynamo/latest/benchmarks/sla_driven_profiling.html#aiperf-on-real-engines
https://docs.nvidia.com/dynamo/latest/benchmarks/sla_driven_profiling.html#interactive-configuration-selection-webui
```
