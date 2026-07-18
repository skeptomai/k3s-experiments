# Alerting Improvements

Gaps identified during the 2026-07-17 etcd death spiral incident. See
`etcd-under-pressure-postmortem.md` for full context.

---

## Current Setup

- **Prometheus** on nazgul, scraping kube-state-metrics (`:30808`) and node-exporter
  (`:30900`) on each node.
- **Alertmanager** routing to Pushover (critical: priority 1, warning: priority 0) and
  email. Config at `home-monitoring/pelagos/config/alertmanager/alertmanager.yml.template`.
- **Rules** at `home-monitoring/pelagos/config/prometheus/rules/alerts.yml`.

---

## Gap 1: Alert notifications lose detail when multiple alerts fire together

**What happened:** vault-0, speaker-nrfhn, and spire-agent-n9v8m all entered
CrashLoopBackOff around the same time. Alertmanager grouped them into one Pushover
notification (grouped by `alertname + severity`). The template only shows the
`description` annotation (which has the `kubectl describe` command) when exactly one
alert is firing — multi-alert groups suppress it. The Pushover title just said
`Critical: KubePodCrashLoopBackOff ×3` with no pod names visible at a glance.

**Fix 1a — Always show description in Pushover message:**

In `alertmanager.yml.template`, change the message template for both receivers from:

```yaml
message: "{{ range .Alerts.Firing }}• {{ .Annotations.summary }}\n{{ end }}{{ if eq (len .Alerts.Firing) 1 }}{{ with (index .Alerts.Firing 0).Annotations.description }}\n{{ . }}{{ end }}{{ end }}"
```

to:

```yaml
message: "{{ range .Alerts.Firing }}• {{ .Annotations.summary }}\n{{ end }}{{ range .Alerts.Firing }}{{ with .Annotations.description }}↳ {{ . }}\n{{ end }}{{ end }}"
```

This shows a description line under each summary bullet, even when multiple alerts are
grouped together.

**Fix 1b — Include node in crash loop grouping:**

Change the route's `group_by` from:

```yaml
group_by: ['alertname', 'severity']
```

to:

```yaml
group_by: ['alertname', 'severity', 'node']
```

This separates notifications by node, so `KubePodCrashLoopBackOff` on ipc5 and ipc8
arrive as distinct notifications rather than a merged blob. Requires adding `node` to
the alert labels (see Gap 2 below).

---

## Gap 2: Crash loop alert missing node name

**What happened:** The `KubePodCrashLoopBackOff` annotation shows namespace/pod/container
but not the node. When multiple pods on ipc5 were crash-looping because ipc5 was
unhealthy, you couldn't tell from the alert that they shared a node — which is the key
diagnostic fact (same node = node problem, not app problem).

**Fix:** Add `node` label and include it in the annotation. kube-state-metrics exposes
`kube_pod_info` which has the `node` label joinable via `on(pod, namespace)`.

In `alerts.yml`, replace the `KubePodCrashLoopBackOff` rule with:

```yaml
- alert: KubePodCrashLoopBackOff
  expr: |
    max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[10m]) > 0
    * on(namespace, pod) group_left(node)
    kube_pod_info
  for: 15m
  labels:
    severity: critical
    component: k3s
  annotations:
    summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) crash-looping on {{ $labels.node }}"
    description: "Container {{ $labels.container }} in {{ $labels.namespace }}/{{ $labels.pod }} on {{ $labels.node }} has been crash-looping >15m. kubectl -n {{ $labels.namespace }} describe pod {{ $labels.pod }}"
```

Apply the same `* on(namespace, pod) group_left(node) kube_pod_info` join to
`KubePodContainerRestarting` and `KubePodNotReady` for the same reason.

---

## Gap 3: No node CPU/load alert

**What happened:** ipc5 reached load average 14 on a 12-thread machine (117% per core)
and stayed there for hours. No alert fired. The node remained `Ready` so
`KubeNodeNotReady` didn't trigger. The only signal was the downstream effects
(crash-looping pods).

**Fix:** Add a node load alert using node-exporter's `node_load1` metric (already being
scraped via the `k3s_nodes` job). Add to `alerts.yml`:

```yaml
- name: kubernetes.node.resources
  interval: 60s
  rules:
    - alert: KubeNodeHighLoad
      expr: |
        node_load1
        / count without(cpu, mode) (node_cpu_seconds_total{mode="idle"})
        > 0.85
      for: 5m
      labels:
        severity: warning
        component: k3s
      annotations:
        summary: "Node {{ $labels.node }} load at {{ $value | printf \"%.0f\" }}% of CPU capacity"
        description: "1-minute load average on {{ $labels.node }} has been >85% of CPU capacity for 5m. At this level etcd raft latency climbs and kubelet heartbeats can miss deadlines."

    - alert: KubeNodeCriticalLoad
      expr: |
        node_load1
        / count without(cpu, mode) (node_cpu_seconds_total{mode="idle"})
        > 1.5
      for: 3m
      labels:
        severity: critical
        component: k3s
      annotations:
        summary: "Node {{ $labels.node }} critically overloaded ({{ $value | printf \"%.0f\" }}× CPU capacity)"
        description: "1-minute load on {{ $labels.node }} is {{ $value | printf \"%.1f\" }}× CPU count for 3m. etcd GC spiral likely. Consider restarting k3s or rebooting the node."
```

Note: the `node` label on the `k3s_nodes` scrape job is set via the static label in
`prometheus.yml` (`labels: {node: ipcN}`), so it will appear on `node_load1` correctly.

---

## Gap 4: No etcd latency alert

**What happened:** etcd raft reads went from <5ms to 10–18 seconds and stayed there for
hours. No alert fired. The only way to discover this was reading raw `journalctl` output
on ipc5.

**Option A — Scrape k3s etcd metrics (recommended):**

k3s exposes embedded etcd metrics on `https://127.0.0.1:2381/metrics` on each control
plane node, authenticated with the etcd client certs. The most actionable metrics:

- `etcd_server_slow_read_indexes_total` — count of linearizable reads that took >1s
- `etcd_server_slow_apply_total` — count of raft applies that took >1s
- `etcd_disk_wal_fsync_duration_seconds_bucket` — WAL fsync latency histogram

To scrape this, add a scrape job to `prometheus.yml` that runs on each node via a
node-exporter textfile collector sidecar, or configure a dedicated etcd scrape job with
the k3s certs. The certs are at:

```
/var/lib/rancher/k3s/server/tls/etcd/server-client.crt
/var/lib/rancher/k3s/server/tls/etcd/server-client.key
/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt
```

Once scraped, add to `alerts.yml`:

```yaml
- name: kubernetes.etcd
  interval: 60s
  rules:
    - alert: EtcdSlowReads
      expr: increase(etcd_server_slow_read_indexes_total[5m]) > 10
      for: 5m
      labels:
        severity: warning
        component: k3s
      annotations:
        summary: "etcd on {{ $labels.instance }} has {{ $value | printf \"%.0f\" }} slow linearizable reads in 5m"
        description: "Linearizable reads are taking >1s on this etcd member. This precedes the goroutine pile-up that causes kubelet heartbeat failures and NotReady events. Check k3s CPU and heap on the affected node."

    - alert: EtcdHighWALFsyncDuration
      expr: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) > 0.5
      for: 5m
      labels:
        severity: warning
        component: k3s
      annotations:
        summary: "etcd WAL fsync p99 > 500ms on {{ $labels.instance }}"
        description: "Slow WAL fsyncs indicate disk I/O pressure on the etcd node. This blocks raft commits and cascades into slow reads."
```

**Option B — Alert on `KubeNodeNotReady` flapping (simpler, no new scrape job):**

The `KubeNodeNotReady` alert has `for: 5m`, which means a node that goes NotReady and
recovers in 4 minutes never fires. Today ipc5 went NotReady repeatedly in short bursts.
Add a flap detector:

```yaml
- alert: KubeNodeNotReadyFlapping
  expr: changes(kube_node_status_condition{condition="Ready",status="true"}[30m]) > 3
  for: 0m
  labels:
    severity: warning
    component: k3s
  annotations:
    summary: "Node {{ $labels.node }} Ready status changed {{ $value | printf \"%.0f\" }} times in 30m"
    description: "Repeated NotReady transitions on {{ $labels.node }} — likely kubelet heartbeat instability from etcd load or network issues. Does not require sustained NotReady to fire."
```

---

## Gap 5: KubeNodeNotReady threshold too slow

**What happened:** ipc5 going NotReady was already a late-stage symptom — etcd had been
degraded for an hour by then. The 5-minute `for:` means it only fires on a sustained
outage, not the pattern we saw (repeated short NotReady windows).

The flapping alert above (Gap 4 Option B) addresses this. Additionally, reduce the
sustained threshold:

```yaml
- alert: KubeNodeNotReady
  expr: kube_node_status_condition{condition="Ready",status="true"} == 0
  for: 2m   # was 5m — 2m is enough for transient scheduling hiccups to clear
```

---

## Gap 6: No Go heap / k3s process alert

**What happened:** The k3s heap grew from 650MB to 7.6GB over several hours. At 7.6GB
the GC was consuming more CPU than the actual work, but nothing fired. If we'd caught
the heap at 2–3GB the node would still have been functional and a k3s restart (not a
full OS reboot) might have been sufficient.

k3s exposes its Go runtime metrics at `https://<node>:6443/metrics` (with k3s
credentials). The relevant metric is `go_memstats_heap_inuse_bytes`.

Once scraped, alert at:

```yaml
- alert: K3sHeapHigh
  expr: go_memstats_heap_inuse_bytes{job="k3s_server"} > 3e9
  for: 10m
  labels:
    severity: warning
    component: k3s
  annotations:
    summary: "k3s heap on {{ $labels.node }} is {{ $value | humanize }}B"
    description: "k3s Go heap exceeds 3GB on {{ $labels.node }} — goroutine accumulation likely in progress. Restart k3s NOW before the GC death spiral makes the node unmanageable. If restarting k3s doesn't bring heap down within 5m, plan a full OS reboot."
```

---

## Summary of changes

| Change | File | Effort |
|--------|------|--------|
| Always show description in multi-alert Pushover messages | `alertmanager.yml.template` | 2 lines |
| Group crash loop alerts by node | `alertmanager.yml.template` | 1 line |
| Add `node` label to pod-level crash loop alerts | `alerts.yml` | join expression |
| Add node load warning + critical alerts | `alerts.yml` | new group |
| Add etcd slow reads / WAL fsync alerts | `alerts.yml` + prometheus scrape | medium |
| Add KubeNodeNotReady flapping detector | `alerts.yml` | new rule |
| Reduce KubeNodeNotReady `for:` from 5m → 2m | `alerts.yml` | 1 line |
| Add k3s Go heap alert | `alerts.yml` + prometheus scrape | medium |

The two-line Pushover fix and the node load alert are the highest-value/lowest-effort
changes. The node load alert alone would have fired hours before any pod started
crash-looping today.
