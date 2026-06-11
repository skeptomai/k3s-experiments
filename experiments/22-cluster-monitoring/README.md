# Experiment 22: Cluster Monitoring

## What you'll observe

- `node-exporter` running as a DaemonSet on every cluster node, exposing hardware and OS metrics (CPU, memory, disk, network) on port 9100
- `kube-state-metrics` running as a Deployment, exposing Kubernetes object metrics (pod status, deployment counts, resource requests vs limits) on port 30808
- Both scraped by the existing Prometheus on nazgul (192.168.89.2) and visible in Grafana

## Architecture

Rather than deploying a second Prometheus stack inside the cluster, this experiment extends the existing monitoring infrastructure on nazgul outward to cover the k3s cluster. Nazgul's Prometheus already monitors MikroTik, TrueNAS, Plex, and SNMP — the k3s nodes are added as additional scrape targets.

```
nazgul (192.168.89.2)
  pelagos-prometheus ─── scrapes ──► ipc1-5 :9100      (node-exporter, per-node hardware/OS)
                     └── scrapes ──► ipc1:30808        (kube-state-metrics, k8s objects)
```

The MikroTik firewall allows unrestricted bridge-nas → bridge-lan traffic, so nazgul can reach all five ipc nodes directly.

### node-exporter

Runs with `hostNetwork: true` and `hostPID: true` so it can read the host's `/proc`, `/sys`, and filesystem stats without being isolated in a pod network namespace. Each node exposes port 9100 directly on its node IP. The `tolerations: - operator: Exists` ensures it runs on the control plane node too.

### kube-state-metrics

Talks to the Kubernetes API server and generates metrics about cluster objects — how many pods are running/pending/failed, deployment desired vs available replicas, HPA state, node conditions, PVC status, etc. Exposed as a NodePort (30808) so Prometheus on nazgul can reach it at any node's IP.

## Prometheus scrape config (nazgul)

Added to `~/Projects/home-monitoring/pelagos/config/prometheus/prometheus.yml`:

```yaml
- job_name: k3s_nodes
  static_configs:
    - targets: ['192.168.88.53:9100']
      labels: {node: ipc1}
    ...

- job_name: k3s_kube_state_metrics
  static_configs:
    - targets: ['192.168.88.53:30808']
```

After updating the config, run `bash update.sh` on nazgul to reload Prometheus.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `monitoring` namespace |
| `node-exporter.yaml` | DaemonSet on all nodes, hostNetwork, port 9100 |
| `kube-state-metrics.yaml` | Deployment + NodePort 30808 + ClusterRole for API access |

## Running manually

```
kubectl apply -f experiments/22-cluster-monitoring/namespace.yaml
kubectl apply -f experiments/22-cluster-monitoring/node-exporter.yaml
kubectl apply -f experiments/22-cluster-monitoring/kube-state-metrics.yaml
kubectl rollout status daemonset/node-exporter -n monitoring
kubectl rollout status deployment/kube-state-metrics -n monitoring
```

Then on nazgul: `cd ~/Projects/home-monitoring/pelagos && bash update.sh`

Verify targets in Prometheus: `http://nazgul:9090/targets` (or port-forward if off-LAN)

## Useful metric examples

```
# Node CPU usage
100 - (avg by(node) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Node memory available
node_memory_MemAvailable_bytes

# Pod restarts across cluster
rate(kube_pod_container_status_restarts_total[5m]) > 0

# Deployments with unavailable replicas
kube_deployment_status_replicas_unavailable > 0
```
