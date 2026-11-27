# Parseable logs benchmark

This repository contains the JSON log generator and the complete AKS
deployment used to benchmark Parseable, Loki and VictoriaLogs ingestion. It
is based on VictoriaMetrics'
[`logs-benchmark`](https://github.com/VictoriaMetrics/logs-benchmark) harness,
with a Parseable adapter that writes JSON arrays to `/api/v1/ingest`.

## Retained scope

- deterministic structured JSON generation;
- configurable rate ramps, stream cardinality, request batches and workers;
- Parseable, Loki and VictoriaLogs native ingestion adapters;
- the reusable writer/querier Helm chart;
- AKS deployments for Parseable, Loki and VictoriaLogs, plus storage and
  monitoring configuration.

GKE manifests, GKE system overlays, local-kind deployment files and the old
GKE result snapshots are intentionally not included.

## AKS benchmark shape

| Role | AKS node | Pod shape |
| --- | --- | --- |
| Parseable v3.2.7 | `Standard_D8ads_v7` (8 vCPU, 32 GiB) | 7 CPU and 24 GiB requested, no limit |
| Loki 3.7.8 | `Standard_D8ads_v7` (8 vCPU, 32 GiB) | 7 CPU and 24 GiB requested, no limit |
| VictoriaLogs v1.53.0 | `Standard_D8ads_v7` (8 vCPU, 32 GiB) | 7 CPU and 24 GiB requested, no limit |
| JSON generator | `Standard_D32ads_v7` (32 vCPU, 128 GiB) | one writer, 32 send workers per system, 32 generators |
| Monitoring | `Standard_D4ads_v7` (4 vCPU, 16 GiB) | VictoriaMetrics/Grafana chart defaults |

The generator sends 2,000 events per request. Ready-made profiles cover 5,000,
10,000 and 15,000 logical streams, all starting at 150,000 events/s with the
ramp schedules used in the AKS exercise. The included controller executes three
fully clean attempts for every profile, deleting and recreating every engine
disk before each attempt. Loki and VictoriaLogs use one 500 GiB Premium SSD v2
volume each; the official Parseable chart uses separate 500 GiB staging and data
volumes. Every volume is configured for 6,000 IOPS and 200 MB/s. Nothing is
installed in the `default` namespace.

See [the AKS runbook](deploy/aks/README.md) for deployment and cleanup.

## Development

```sh
make test
make build
docker build -t logs-benchmark:dev .
```
