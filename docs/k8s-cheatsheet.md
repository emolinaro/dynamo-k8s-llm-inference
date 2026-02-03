# K8s / Dynamo Ops Cheatsheet

## Variables (edit for your environment)

```sh
export NAMESPACE=your-namespace
export MATCH=your-pattern
```

## Inspect resources

- Watch pods
  ```sh
  kubectl get pods -n $NAMESPACE -o wide -w
  ```

- List Deployments (optionally filtered)
  ```sh
  kubectl get deploy -n $NAMESPACE | grep -E "$MATCH"
  ```

- List Pods (optionally filtered)
  ```sh
  kubectl get pod -n $NAMESPACE | grep -E "$MATCH"
  ```

## Logs

- Pod logs (last 100)
  ```sh
  kubectl logs -n $NAMESPACE $POD --tail=100
  ```

- Deployment logs (last 200)
  ```sh
  kubectl -n $NAMESPACE logs deploy/$DEPLOYMENT --tail=200
  ```

## ConfigMaps

- Create from a file (key is filename by default)
  ```sh
  kubectl create configmap $CM_NAME -n $NAMESPACE --from-file=path/to/file
  ```

- Create from a specific key + file
  ```sh
  kubectl create configmap $CM_NAME -n $NAMESPACE --from-file=config.yaml=path/to/config.yaml
  ```

- Create from literals
  ```sh
  kubectl create configmap $CM_NAME -n $NAMESPACE \
    --from-literal=KEY1=value1 --from-literal=KEY2=value2
  ```

- Create from env file
  ```sh
  kubectl create configmap $CM_NAME -n $NAMESPACE --from-env-file=path/to/envfile
  ```

- Create or update from a manifest
  ```sh
  kubectl apply -n $NAMESPACE -f path/to/configmap.yaml
  ```

- Delete a ConfigMap
  ```sh
  kubectl delete configmap -n $NAMESPACE $CM_NAME
  ```

- Delete ConfigMaps matching a pattern
  ```sh
  kubectl delete configmap -n $NAMESPACE \
    $(kubectl get configmap -n $NAMESPACE | awk -v m="$MATCH" '$0 ~ m {print $1}')
  ```

## Secrets

- Get a secret value (base64 decode)
  ```sh
  KEY=HF_TOKEN # or any other secret key
  kubectl get secret $SECRET -n $NAMESPACE -o jsonpath='{.data.$KEY}' | base64 -d
  ```

## Pod shell

- Open a shell in a pod
  ```sh
  kubectl exec -n $NAMESPACE -it $POD -- sh
  ```

## Ownership

- Find a pod's owner (kind + name)
  ```sh
  POD=$(kubectl get pod -n $NAMESPACE -o name | grep -E "$MATCH" | head -n1 | cut -d/ -f2)
  kubectl get pod -n $NAMESPACE "$POD" \
    -o jsonpath='{.metadata.ownerReferences[*].kind}{" "}{.metadata.ownerReferences[*].name}{"\n"}'
  ```

## Scale down and clean up Deployments

- Scale all matching Deployments to 0
  ```sh
  kubectl scale deploy -n $NAMESPACE --replicas=0 \
    $(kubectl get deploy -n $NAMESPACE | awk -v m="$MATCH" '$0 ~ m {print $1}')
  ```

- Verify replicas are 0
  ```sh
  kubectl get deploy -n $NAMESPACE | grep -E "$MATCH"
  ```

- Delete remaining pods (matching)
  ```sh
  kubectl delete pod -n $NAMESPACE \
    $(kubectl get pod -n $NAMESPACE | awk -v m="$MATCH" '$0 ~ m {print $1}')
  ```

- Force-delete pods (matching)
  ```sh
  kubectl delete pod -n $NAMESPACE --force --grace-period=0 \
    $(kubectl get pod -n $NAMESPACE | awk -v m="$MATCH" '$0 ~ m {print $1}')
  ```

## DynamoComponentDeployment cleanup

- List all DynamoComponentDeployments
  ```sh
  kubectl get dynamocomponentdeployment -n $NAMESPACE
  ```

- Delete specific DynamoComponentDeployments
  ```sh
  kubectl delete dynamocomponentdeployment -n $NAMESPACE $DCD
  kubectl delete dynamocomponentdeployment -n $NAMESPACE \
    $DCD_1 $DCD_2 $DCD_3 $DCD_4 2>/dev/null || true
  ```

- Delete all matching DynamoComponentDeployments
  ```sh
  kubectl delete dynamocomponentdeployment -n $NAMESPACE \
    $(kubectl get dynamocomponentdeployment -n $NAMESPACE | awk -v m="$MATCH" '$0 ~ m {print $1}')
  ```

- Find owner of a DynamoComponentDeployment
  ```sh
  kubectl get dynamocomponentdeployment -n $NAMESPACE $DCD \
    -o jsonpath='{.metadata.ownerReferences}{"\n"}'
  ```

- If owner is a DynamoGraphDeploymentRequest, delete it
  ```sh
  kubectl delete dynamographdeploymentrequest -n $NAMESPACE $DGDR_REQ
  ```

## DynamoGraphDeployment

- List graph deployments
  ```sh
  kubectl -n $NAMESPACE get dynamographdeployments
  ```

- Delete a DynamoGraphDeployment
  ```sh
  kubectl delete dynamographdeployment -n $NAMESPACE $DGDR
  ```
