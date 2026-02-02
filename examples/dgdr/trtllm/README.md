# DGDR example: Qwen/Qwen3-0.6B (TRT-LLM)

This example demonstrates a DynamoGraphDeploymentRequest (DGDR) that references a
TRT-LLM disaggregated deployment template via a ConfigMap.

## Files
- `disagg.yaml`: DynamoGraphDeployment template (prefill + decode)
- `dgdr.yaml`: DynamoGraphDeploymentRequest that references the ConfigMap
- `run-dgdr.sh`: helper to create/update the ConfigMap and apply the DGDR

## Notes
- SLA targets are sized for a 1-node cluster with 2x A100 GPUs. Tightening these
  typically requires more GPUs than this cluster provides.

## Manual ConfigMap creation

```bash
export NAMESPACE=dynamo-system
kubectl create configmap qwen-config \
  --from-file=disagg.yaml=/path/to/disagg.yaml \
  --namespace $NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Run

```bash
./run-dgdr.sh
```

Override defaults via env vars:

```bash
NAMESPACE=dynamo-system CONFIGMAP_NAME=qwen-config ./run-dgdr.sh
```

## Frontend NodePort

Expose the frontend service on a fixed NodePort:

```bash
export NAMESPACE=dynamo-system
export FRONTEND_NODEPORT=30081
export FRONTEND_SVC=$(kubectl -n $NAMESPACE get svc --no-headers | awk '/frontend/ {print $1; exit}')
kubectl patch svc "$FRONTEND_SVC" -n "$NAMESPACE" --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},{\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${FRONTEND_NODEPORT}}]"
```

Access it:

```bash
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "http://$NODE_IP:$FRONTEND_NODEPORT"
```

## Multi-user conversation test

Run parallel conversations against the deployed endpoint:

```bash
NUM_CONVOS=20 CONCURRENCY=8 ./multi_convos_parallel.sh
```

Override endpoint/model if needed:

```bash
API_URL=http://<NODE_IP>:30081/v1/chat/completions MODEL=Qwen/Qwen3-0.6B ./multi_convos_parallel.sh
```

## Grafana Dynamo dashboard

Apply the dashboard ConfigMap:

```bash
kubectl apply -n monitoring -f ./grafana-dynamo-dashboard-configmap.yaml
```

Get Grafana credentials:

```bash
export GRAFANA_USER=$(kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-user}" | base64 --decode)
export GRAFANA_PASSWORD=$(kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
echo "Grafana user: $GRAFANA_USER"
echo "Grafana password: $GRAFANA_PASSWORD"
```

Expose Grafana as a NodePort (avoid port-forwarding):

```bash
kubectl patch svc prometheus-grafana -n monitoring -p '{"spec":{"type":"NodePort","ports":[{"name":"service","port":80,"targetPort":3000,"protocol":"TCP","nodePort":30080}]}}'
```

Open Grafana at:

```
http://<NODE_IP>:30080
```
