# Log Aggregation Plan: Loki + Promtail

## Why

`docs/ipc7-elevated-restarts-investigation.md` hit a concrete, demonstrated
gap: by the time anyone noticed ipc7's elevated restart counts, the actual
crash evidence was permanently gone. Two distinct reasons, not one:

1. **Container log retention is node-local and bounded by design.**
   `kubectl logs --previous` reads log files kubelet writes per-node; once a
   container cycles through enough restarts, the earliest logs are deleted,
   not just hard to find. This is normal/expected everywhere, not a bug.
2. **`ContainerStatus.LastState` was empty** despite thousands of restarts —
   filed separately as pelagos#557, since containerd normally retains the
   most recent termination's reason/exit code independent of log-file
   retention. That's a CRI gap worth fixing on its own regardless of
   whether this plan happens.
3. **pelagos-cri and k3s are systemd services, not pods** — their own
   crash/restart history lives only in each node's journal
   (`journalctl -u pelagos-cri`), same bounded-retention problem, and
   `kubectl` has zero visibility into it at all.

None of these are fixed by better alerting (already added:
`KubePodRestartingTooOften` / `KubeNodeRestartRateHigh`,
`home-monitoring` commit `dd677c3`) — alerting says "something's wrong,"
it doesn't preserve *why* long enough to diagnose it after the fact.

## Non-goal

This is not a replacement for the alerting just added, and not a case for
moving Prometheus in-cluster (see the discussion in this repo's own commit
history / conversation record around 2026-09-30 — the external-Prometheus
architecture is working and isn't being revisited here). This is
specifically about **log retention surviving longer than kubelet's local
rotation**, nothing else.

## Architecture

Same pattern as the existing metrics stack: lightweight collection
in-cluster, aggregation/storage on nazgul. Nothing conceptually new.

- **Loki**, added to nazgul's existing Pelagos-managed monitoring stack
  (`home-monitoring/pelagos/compose-truenas.reml`, alongside the existing
  `svc-prometheus`/`svc-grafana` services) — same `.reml` `define-service`
  pattern, same ZFS-backed bind-mount convention as `prometheus-data`/
  `grafana-data` (14.4T available on `primary_storage`, not a sizing
  concern). Single-binary Loki (filesystem storage backend, not
  microservices mode) — this cluster's log volume doesn't justify more.
- **Promtail** as a DaemonSet in-cluster (`manifests/promtail/`,
  Flux-managed like every other real app), one per node (ipc4-9; the
  `aws-graviton-build` cloud node is out of scope for now — it's
  intermittently stopped and not part of the steady-state cluster this is
  protecting). Two log sources per node:
  - Container logs: hostPath mount of `/var/log/pods` (standard Promtail
    Kubernetes service-discovery config — auto-discovers every pod's logs,
    no per-app configuration needed).
  - **systemd journal**: hostPath mount of `/var/log/journal` (or
    `/run/log/journal` if persistent journaling isn't enabled — check and
    enable persistent journaling if not, otherwise the journal itself is
    memory-only and doesn't survive a reboot, defeating the point),
    Promtail's `journal:` scrape stage, scoped to at least
    `pelagos-cri.service` and `k3s`/`k3s-agent.service` — this is the piece
    that would have caught a pelagos-cri-level crash, which nothing else
    here does.
  - Ships to `http://192.168.89.2:<loki-port>/loki/api/v1/push` — plain LAN
    IP, same as every other exporter/scrape target in this cluster, no
    Tailscale involved.
- **Grafana datasource**: add a `Loki` entry to
  `home-monitoring/pelagos/config/grafana/provisioning/datasources/datasources.yaml`
  (currently only has `Prometheus`) — Grafana already runs on nazgul, no
  new dashboard tool.

## Retention

Loki's own retention (compactor `retention_period`) should be generous but
not infinite — 14.4T free makes this a non-issue for a home cluster's log
volume; start at 30 days and revisit if it's ever actually tight (a real
measurement, not a guess up front, matching the honesty standard the
`KubeNodeRestartRateHigh` threshold was held to). The point is "survives
longer than kubelet's local rotation," not "forever."

## Files to create/change

- `home-monitoring/pelagos/compose-truenas.reml` — add `svc-loki`.
- `home-monitoring/pelagos/config/loki/loki-config.yaml` — filesystem
  storage backend, retention config.
- `home-monitoring/pelagos/config/grafana/provisioning/datasources/datasources.yaml` —
  add the Loki datasource.
- `manifests/promtail/` (daemonset.yaml, configmap.yaml, rbac.yaml,
  kustomization.yaml) — the in-cluster collector, wired into the relevant
  Flux Kustomization the way other apps here are.
- `docs/loki-log-aggregation-plan.md` — this doc.

## Verification

- `kubectl get pods -n <promtail-namespace> -o wide` — one Promtail pod
  per node (ipc4-9), all `Running`.
- Query Loki directly (via nazgul, or Grafana's Explore view) for a known
  recent log line from a real pod — proves container-log shipping works
  end to end, not just that Promtail started.
- **The actual point of this whole exercise**: query Loki for
  `pelagos-cri.service` journal entries and confirm real systemd journal
  content shows up — this is the source that was completely invisible
  before.
- Induce one deliberate, harmless restart (e.g. delete a non-critical pod)
  and confirm its logs are queryable in Loki *after* kubectl's own
  `--previous` access would normally still work — not a strong test of
  long-term retention, but confirms the pipeline is live end-to-end.
