# Experiment 22 — Cluster Monitoring

This experiment extends the existing Prometheus stack on nazgul outward to cover the k3s cluster, rather than deploying a second monitoring stack inside the cluster. Node-exporter provides per-node hardware and OS metrics (CPU, memory, disk, network) via a DaemonSet, while kube-state-metrics exposes Kubernetes object state (pod status, deployment health, resource requests vs limits) via a Deployment. Both are exposed as NodePort services so nazgul's Prometheus can scrape them directly over the LAN without any in-cluster Prometheus.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `monitoring` namespace |
| `node-exporter.yaml` | DaemonSet on all nodes exposing host metrics on NodePort 30900, plus hostPath mounts for `/sys` and `/` |
| `kube-state-metrics.yaml` | Deployment with ClusterRole for API access, exposed on NodePort 30808 |

## Apply

```
kubectl apply -f experiments/22-cluster-monitoring/namespace.yaml
kubectl apply -f experiments/22-cluster-monitoring/node-exporter.yaml
kubectl apply -f experiments/22-cluster-monitoring/kube-state-metrics.yaml
```

## Observe

1. Verify all six node-exporter pods are Running (one per node):
   `kubectl get pods -n monitoring -o wide`

2. Grab a node IP and curl node-exporter directly to confirm metrics are flowing:
   `kubectl get nodes -o wide` then `curl http://<node-ip>:30900/metrics | head -20`

3. Curl kube-state-metrics at NodePort 30808:
   `curl http://<node-ip>:30808/metrics | grep kube_pod_info | head -5`

4. On nazgul, the prometheus scrape config (`~/Projects/home-monitoring/pelagos/config/prometheus/prometheus.yml`) should have a `k3s_nodes` job with targets for each node at port 30900 and a `k3s_kube_state_metrics` job targeting port 30808. After any config changes, reload with `bash update.sh` on nazgul.

5. In Grafana, node-exporter metrics appear under the `k3s_nodes` job; kube-state-metrics under `k3s_kube_state_metrics`. Useful starting queries: `node_cpu_seconds_total`, `kube_pod_status_phase`, `kube_deployment_status_replicas_available`.

**Pelagos note:** node-exporter runs without `hostNetwork` or `hostPID` (Pelagos does not support these). The `externalTrafficPolicy: Local` on the NodePort Service ensures each node's traffic routes to its own pod, preserving per-node identity in metrics. Pelagos already exposes host-level `/proc/meminfo` and `/proc/stat` inside the container namespace, so `--path.procfs` is omitted; `/host/sys` is mounted explicitly to avoid a panic on nodes where Pelagos does not expose `/sys` in the container namespace by default.

## Teardown

`kubectl delete namespace monitoring`
