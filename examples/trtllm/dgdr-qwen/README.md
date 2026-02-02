# DGDR example: Qwen/Qwen3-0.6B (TRT-LLM)

This example demonstrates a DynamoGraphDeploymentRequest (DGDR) that references a
TRT-LLM disaggregated deployment template via a ConfigMap.

## Files
- disagg.yaml: DynamoGraphDeployment template (prefill + decode)
- dgdr.yaml: DynamoGraphDeploymentRequest that references the ConfigMap
- run-dgdr.sh: helper to create/update the ConfigMap and apply the DGDR

## Notes
- SLA targets are sized for a 1-node cluster with 2x A100 GPUs. Tightening these
  typically requires more PGUs than this cluster provides.

## Manual ConfigMap creation

```bash
export NAMESPACE=dynamo-system
kubectl create configmap qwen-config \
  --from-file=disagg.yaml=path/to/disagg.yaml \
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
