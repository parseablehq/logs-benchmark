# AKS three-system ingestion benchmark

This runbook recreates the Parseable, Loki and VictoriaLogs ingestion setup.
Every measured engine has an identical dedicated node and disk. The writer and
monitoring run on separate nodes and are not included in engine resource use.
Nothing is installed in the `default` namespace.

## Pinned software and infrastructure

| Role | Software | AKS node pool |
| --- | --- | --- |
| Parseable | Parseable v3.2.7 | 1 × `Standard_D8ads_v7` |
| Loki | chart 18.15.1, Loki 3.7.8 | 1 × `Standard_D8ads_v7` |
| VictoriaLogs | chart 0.13.10, VictoriaLogs v1.53.0 | 1 × `Standard_D8ads_v7` |
| Harness | this repository's image | 1 × `Standard_D32ads_v7` |
| Monitoring | VictoriaMetrics stack chart 0.91.2 | 1 × `Standard_D4ads_v7` |

Each engine requests 7 CPU and 24 GiB without a resource limit. Loki and
VictoriaLogs each use one 500 GiB Premium SSD v2 volume. The official Parseable
chart creates separate 500 GiB staging and data volumes. Every volume is set to
6,000 IOPS and 200 MB/s. The writer uses 32 generator goroutines, 32 request
workers per engine and 2,000-event batches.

The repository includes all three measured source-cardinality profiles:

| Profile | Hosts × apps | Logical streams | Start | Ramp |
| --- | --- | ---: | ---: | --- |
| `5k` | 125 × 40 | 5,000 | 150k/s | +20k every 10 minutes |
| `10k` | 250 × 40 | 10,000 | 150k/s | +20k every 10 minutes |
| `15k` | 375 × 40 | 15,000 | 150k/s | +20k every 10 minutes |

Prerequisites: Azure CLI, `kubectl`, Helm 3, an Azure subscription, and an ACR
name that is globally unique.

## 1. Create the AKS infrastructure

Set the names once:

```sh
export LOCATION=eastus
export RESOURCE_GROUP=rg-parseable-test
export AKS_CLUSTER=parseable-bench
export ACR_NAME=REPLACE_WITH_GLOBALLY_UNIQUE_ACR_NAME
```

Create the resource group, the AKS system pool and the registry:

```sh
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_CLUSTER" \
  --location "$LOCATION" \
  --nodepool-name system \
  --node-count 1 \
  --node-vm-size Standard_D4ads_v7 \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --generate-ssh-keys
az acr create --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --sku Basic
az aks update --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER" \
  --attach-acr "$ACR_NAME"
```

Add isolated user pools. Labels select the pool; taints keep unrelated pods
off the measured nodes:

```sh
az aks nodepool add -g "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER" \
  -n parseable --node-count 1 --node-vm-size Standard_D8ads_v7 --mode User \
  --labels workload=parseable --node-taints workload=parseable:NoSchedule
az aks nodepool add -g "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER" \
  -n loki --node-count 1 --node-vm-size Standard_D8ads_v7 --mode User \
  --labels workload=loki --node-taints workload=loki:NoSchedule
az aks nodepool add -g "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER" \
  -n victorialogs --node-count 1 --node-vm-size Standard_D8ads_v7 --mode User \
  --labels workload=victorialogs \
  --node-taints workload=victorialogs:NoSchedule
az aks nodepool add -g "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER" \
  -n harness --node-count 1 --node-vm-size Standard_D32ads_v7 --mode User \
  --labels workload=harness --node-taints workload=harness:NoSchedule
az aks nodepool add -g "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER" \
  -n monitoring --node-count 1 --node-vm-size Standard_D4ads_v7 --mode User \
  --labels workload=monitoring --node-taints workload=monitoring:NoSchedule
```

Fetch credentials and confirm placement metadata:

```sh
az aks get-credentials -g "$RESOURCE_GROUP" -n "$AKS_CLUSTER" --overwrite-existing
kubectl get nodes -L workload,kubernetes.azure.com/agentpool
```

## 2. Build the benchmark images

The upstream public image does not contain this repository's Parseable
adapter. Build the writer and the small in-cluster run controller in ACR:

```sh
az acr build --registry "$ACR_NAME" --image logs-benchmark:aks .
az acr build --registry "$ACR_NAME" \
  --file deploy/aks/controller.Dockerfile \
  --image logs-benchmark-controller:aks .
export ACR_LOGIN_SERVER="$(az acr show -n "$ACR_NAME" --query loginServer -o tsv)"
```

## 3. Create namespaces, secrets and storage

```sh
kubectl apply -f deploy/aks/namespaces.yaml
kubectl -n logs-bench-parseable create secret generic parseable-env-secret \
  --from-literal=addr=0.0.0.0:8000 \
  --from-literal=username="$PARSEABLE_USERNAME" \
  --from-literal=password="$PARSEABLE_PASSWORD"
kubectl -n logs-bench-harness create secret generic parseable-auth \
  --from-literal=PARSEABLE_USERNAME="$PARSEABLE_USERNAME" \
  --from-literal=PARSEABLE_PASSWORD="$PARSEABLE_PASSWORD" \
  --from-literal=PARSEABLE_STREAM=logs-bench
kubectl apply -f deploy/aks/storage-class.yaml
```

## 4. Install all three systems with Helm

```sh
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo add parseable https://charts.parseable.com
helm repo update

helm upgrade --install parseable parseable/parseable \
  --version 3.2.7 \
  --namespace logs-bench-parseable \
  --values deploy/aks/parseable-values.yaml \
  --wait --timeout 10m
helm upgrade --install loki grafana-community/loki \
  --version 18.15.1 --namespace logs-bench-loki \
  -f deploy/aks/loki-values.yaml
helm upgrade --install victorialogs vm/victoria-logs-single \
  --version 0.13.10 --namespace logs-bench-victorialogs \
  -f deploy/aks/victorialogs-values.yaml
```

The Parseable override pins v3.2.7 and configures local storage, benchmark
resources, conversion cadence and isolated node placement.

Wait for the engine pods and verify that each landed on its dedicated node:

```sh
kubectl wait --for=condition=Ready pod --all -n logs-bench-parseable --timeout=10m
kubectl wait --for=condition=Ready pod --all -n logs-bench-loki --timeout=10m
kubectl wait --for=condition=Ready pod --all -n logs-bench-victorialogs --timeout=10m
kubectl get pods -A -o wide
kubectl get pvc -A
```

## 5. Install monitoring and the stopped harness

```sh
helm upgrade --install monitoring vm/victoria-metrics-k8s-stack \
  --version 0.91.2 --namespace logs-bench-monitoring \
  -f deploy/aks/monitoring-values.yaml
kubectl wait --for=condition=Established \
  crd/vmpodscrapes.operator.victoriametrics.com --timeout=2m
kubectl apply -f deploy/aks/benchmark-scrape.yaml

export PROFILE=5k
helm upgrade --install bench deploy/chart \
  --namespace logs-bench-harness \
  -f deploy/aks/load-generator-values.yaml \
  -f "deploy/aks/profiles/${PROFILE}.yaml" \
  --set-string image.repository="$ACR_LOGIN_SERVER/logs-benchmark"
```

The writer is intentionally installed with zero replicas. The querier polls
server-side stored counts but does not run latency queries during ingestion.
Open Grafana locally with:

```sh
kubectl -n logs-bench-monitoring port-forward svc/monitoring-grafana 3000:80
```

## 6. Run three clean attempts for every profile

The controller runs this fixed order without requiring an attached terminal:

```text
5k-1, 5k-2, 5k-3, 10k-1, 10k-2, 10k-3, 15k-1, 15k-2, 15k-3
```

Every attempt is independent. The controller stops the load and all three
engines, waits for their pods to terminate, deletes and verifies all three
benchmark PVCs, starts the engines on new PVCs, and records a 10-minute idle
baseline. It then runs 150k/s through 510k/s in 20k/s steps held for 10 minutes
each and retains five minutes of settled metrics before the next cleanup. One
deterministic event is fanned out to all systems; `dropOnFull: true` prevents a
slow engine from throttling the others.

This operation intentionally deletes all existing benchmark data in the three
engine namespaces. Launch the controller after replacing the image placeholder:

```sh
sed "s|REPLACE_WITH_ACR_LOGIN_SERVER|$ACR_LOGIN_SERVER|g" \
  deploy/aks/run-nine-attempts.yaml | kubectl apply -f -
```

The full sequence takes roughly 31 hours plus pod and disk provisioning time.
It stores timestamps, progress and outcomes in a ConfigMap and leaves monitoring
running after scaling the writer, querier and engines to zero:

```sh
kubectl -n logs-bench-monitoring logs -f job/benchmark-nine-run-controller
kubectl -n logs-bench-monitoring get configmap benchmark-nine-run-state -o yaml
```

On failure or interruption, the controller stops the load but leaves the engine
pods and their current data available for diagnosis. To start a new complete
nine-run sequence, delete only the completed/failed controller Job and apply the
manifest again:

```sh
kubectl -n logs-bench-monitoring delete job benchmark-nine-run-controller \
  --ignore-not-found
sed "s|REPLACE_WITH_ACR_LOGIN_SERVER|$ACR_LOGIN_SERVER|g" \
  deploy/aks/run-nine-attempts.yaml | kubectl apply -f -
```

For a single manual run, scale `deployment/writer` to one. Stop it by scaling it
back to zero. The installed 5k profile is the manual-run default.

## 7. Teardown

Remove benchmark workloads but retain the AKS cluster:

```sh
sed "s|REPLACE_WITH_ACR_LOGIN_SERVER|$ACR_LOGIN_SERVER|g" \
  deploy/aks/run-nine-attempts.yaml | kubectl delete -f - --ignore-not-found
kubectl -n logs-bench-harness scale deployment/writer --replicas=0
helm uninstall bench -n logs-bench-harness
kubectl delete -f deploy/aks/benchmark-scrape.yaml --ignore-not-found
helm uninstall monitoring -n logs-bench-monitoring
helm uninstall parseable -n logs-bench-parseable --ignore-not-found
helm uninstall loki -n logs-bench-loki --ignore-not-found
helm uninstall victorialogs -n logs-bench-victorialogs --ignore-not-found
kubectl delete -f deploy/aks/namespaces.yaml
```

Deleting the resource group removes the cluster, disks and registry and cannot
be undone:

```sh
az group delete --name "$RESOURCE_GROUP"
```
