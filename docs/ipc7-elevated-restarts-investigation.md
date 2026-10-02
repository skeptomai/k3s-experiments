# ipc7 Elevated Restarts — RESOLVED (2026-09-30)

**Update 2026-09-30, later same day**: root cause found and fixed,
independently of this investigation thread — this was pelagos-cri's
sandbox-state-on-restart bug (pelagos#553, fixed in PR#555/v0.65.98,
cluster-wide rollout to v0.65.99). The restart counts documented below are
the historical scar tissue from that bug; confirmed live that they've
stopped growing since the fix landed (frozen at the same totals). See
`docs/tailscale-operator-device-outage-2026-09-28.md`'s sibling postmortem
style for the full incident if a dedicated writeup is ever wanted — for now
this doc stands as the investigation record, now closed.

The two suggested alerting improvements (per-pod and per-node
container-restart-rate rules) were implemented in `home-monitoring`
(`pelagos/config/prometheus/rules/alerts.yml`, `KubePodRestartingTooOften` /
`KubeNodeRestartRateHigh`, commit `dd677c3`) — this is exactly the
before/after example: the data (`kube_pod_container_status_restarts_total`)
was always there, nothing was watching it, now something is.

**Update 2026-10-01**: the specific `lastState` gap documented below (line
53 — empty on `cilium-knvpg`/`cilium-envoy-kz7tr` despite thousands of
restarts) was filed as pelagos#557, root-caused, and fixed in
[PR #558](https://github.com/pelagos-containers/pelagos/pull/558) (merged
`51867b0`, released as v0.65.100). Root cause was **not** pelagos-cri
failing to populate `lastState` in general — a plain crash-looping
container correctly reports `lastState` across a `pelagos-cri` restart.
The actual bug: `pelagos-cri`'s existing `#457` recovery path (force-kills
any *running* hostNetwork container on its own startup, via `pelagos stop
--time 0`, to release the container's host-network port binding, then
marks it `Exited` so kubelet reschedules a replacement) left `exit_code` at
its pre-exit default of `0` instead of recording the real SIGKILL. A
force-killed container was therefore indistinguishable from a clean exit
in `ContainerStatus`, which is exactly what left `lastState` unable to
carry any useful reason — this is almost certainly what happened to
`cilium-knvpg`/`cilium-envoy-kz7tr` historically, every time `pelagos-cri`
itself restarted while they were running. Fixed by setting `exit_code` to
`137` (128+SIGKILL, matching the existing OOM-kill convention) on that
path. Verified live and in place on ipc7 (not on the two originally-named
pods, which had already rolled past this by the time of the fix): before
the fix, a hostNetwork test pod's `lastState.terminated` showed
`exitCode:0` with no `reason` after a `pelagos-cri` restart; after
deploying the fix, the identical scenario showed `exitCode:137`.

**Addendum to the addendum, same day**: a separate agent, mid-investigation
of *this* doc, flagged what looked like a resurfacing of #553 — `ipc7`
alone showing new Cilium-agent/speaker restarts (4842→4845,
1931→1934) and running a different pelagos build hash
(`0.65.99+13abb68`) than the rest of the fleet (`0.65.99+3755891`). That
was correctly-read raw data but an incorrect inference: `13abb68` is the
commit of the `fix/cri-last-state-557` branch above, deployed *only* to
ipc7 (the cluster's single build+test guinea pig, via
`home-monitoring/pelagos-build/cluster-build.sh`) while diagnosing and
verifying #557 — not a fleet rollout, and not `#553` reappearing. Every
`pelagos-cri` restart during that work (4 total, confirmed via
`journalctl -u pelagos-cri` on ipc7: 2026-09-30T23:47:27Z, 23:49:05Z,
23:52:46Z, 23:53:04Z) re-triggered the same pre-existing, correctly-working
`#457` hostNetwork-port-release logic described above, which is what
bumped those two DaemonSets' restart counts on that one node. `#553`
remains fixed; nothing regressed. The one real loose end this left behind
was operational, not a bug: ipc7 was sitting on a one-off dev build
instead of the fleet's official release. Resolution (approved by the repo
owner): once v0.65.100 finishes release CI, roll it out to **all six
nodes including ipc7** in one pass, converging everyone on the same
official binary, rather than reverting ipc7 to the older release first.

**Update 2026-10-02, afternoon**: the same false-alarm shape recurred a third
time (second time being mistaken for a health issue), this time from a
different investigating session (the `k8s-scaling` one, prompted by a
physical-hardware concern about `ipc7`). At 14:33 UTC, Alertmanager's
`KubePodRestartingTooOften` fired again for `cilium-knvpg` /
`cilium-envoy-kz7tr` on `ipc7`. Full check performed before concluding
anything: current/historical `node_hwmon_temp_celsius` on `ipc7` around the
event (flat, 33-39°C NVMe / 35-59°C CPU, no spike, no sensor anomaly beyond
the universal `-266.9°C` `thermal_zone0` artifact present on all six nodes);
`node_boot_time_seconds` unchanged from the shared ~12:00 UTC nightly
power-cycle (the node itself never rebooted); journal searched for
OOM/panic/segfault/MCE/disk-I/O/NIC-reset/ECC/Xid patterns in the restart
window (nothing); `node_network_receive_errs_total` /
`transmit_errs_total` / `node_disk_io_now` all zero fleet-wide. The journal
showed `pelagos_cri` receiving a clean `SIGTERM` at 14:30:06Z and again at
14:31:16Z, then a full k3s-agent (kubelet+kube-proxy) cold start at
14:33:24-27Z — a deliberate service restart, not a crash.

Root cause, same shape as the #557 addendum above: `ipc7` was running
`pelagos://0.65.100+3646e7d` while the rest of the fleet sat on
`pelagos://0.65.100+39720b5`. `3646e7d` is **not a tagged release**
(`git describe` → `v0.65.100-2-g3646e7d`, i.e. two commits past the
`v0.65.100` tag) — it's commit `fix: mount fresh /run tmpfs in CRI
containers; stop layer-extraction GID leak` on branch
`fix/run-tmpfs-gid-leak-559`, deployed to `ipc7` alone as the cluster's
single build+test guinea pig, exactly as `13abb68`/#557 was. The restart
counts ticked up by a small, one-time amount (+7/+8) consistent with the
one deploy event, not a crash loop, and Cilium came back fully healthy
immediately after (`cilium-dbg status`: 52/52 controllers healthy, cluster
health 6/6 reachable, 0 degraded modules).

**Standing lesson, now confirmed twice**: before treating any ipc7-specific
restart/alert as a sign of a problem, check
`kubectl get nodes -o custom-columns=NAME:.metadata.name,RUNTIME:.status.nodeInfo.containerRuntimeVersion`
for a build-hash mismatch against the rest of the fleet first. `ipc7` being
the designated dev-build guinea pig node means it will periodically run a
different (unreleased) binary than everyone else, and that alone reliably
explains an isolated restart with no other symptoms.

## Summary

While reviewing the cluster's IPVS/Cilium/MetalLB history for an unrelated writeup, live `kubectl` inspection turned up a real, currently-unexplained anomaly: **`ipc7` shows dramatically elevated lifetime restart counts across two unrelated DaemonSets** (Cilium's own pods, and MetalLB's speaker) compared to every other node. Root cause is **not** found — this doc is the investigation record and a handoff, not a postmortem with a resolution.

Also surfaced in the same pass: **no Prometheus/Grafana/Alertmanager runs inside this cluster** — only `kube-state-metrics` and `node-exporter` (bare exporters). If something on `nazgul` scrapes these and already alerts on restart rates, this doc's alerting recommendation may be redundant — check there first.

## The finding

Restart counts as of 2026-09-30 ~23:15 UTC:

| DaemonSet | `ipc7` | Every other node | Ratio |
|---|---|---|---|
| `cilium-agent` | 4,842 | 43–44 | ~110x |
| `cilium-envoy` | 4,811 | 43–45 | ~107x |
| `metallb speaker` | 1,931 | 85–117 | ~17–23x |

Same node, three different pods, two unrelated pieces of software (Cilium and MetalLB) — this points at something about the node, not a Cilium-specific or MetalLB-specific bug.

## Timing: the most recent restart is a red herring

All pods of both DaemonSets — on **every** node, not just `ipc7` — restarted within the same ~30-second window on 2026-09-30, approximately 12:01 UTC (Cilium: 12:01:27–12:01:43Z across all 6 nodes; MetalLB speaker: 12:01:09–12:01:38Z across all 6 nodes). That's a single synchronized cluster-wide event, not six independent crashes, and it lines up exactly with the documented `night-off`/`morning-on` power-cycle (`ipc4-pod-pileup-postmortem.md`: all nodes cordon+drain+power-off together, then uncordon together each morning — restarting every DaemonSet pod on every node in one wave).

**The most recent restart on either DaemonSet is not evidence of an active, ongoing problem.** The real signal is the *lifetime total*, not the timestamp of the last one.

## What's been ruled out

- **Current resource pressure**: `ipc7`'s `MemoryPressure` / `DiskPressure` / `PIDPressure` conditions are all `False`; node is `Ready`. Checked via `kubectl describe node ipc7`.
- **VM contention**: `kubectl get vmi -A` returns zero running `VirtualMachineInstance`s anywhere in the cluster right now. KubeVirt is installed but idle cluster-wide — `ipc7` is not hosting VMs that could be starving these pods of CPU/network.

## What's unknown, and why

The actual crash reason for the historical restarts could not be determined from the live cluster:

- `kubectl get pod <name> -o json` → `.status.containerStatuses[].lastState` is **empty** on both `cilium-knvpg` and `cilium-envoy-kz7tr`, despite restart counts in the thousands.
- `kubectl logs <name> --previous` → `Error from server (BadRequest): previous terminated container ... not found` for both.
- Default event TTL (~1h) means anything from before today is gone from `kubectl get events`.

Whether this is Pelagos not preserving previous-container state the way containerd would, or kubelet GC, wasn't determined. **If there's log retention anywhere outside kubectl's own memory of it — Loki, or whatever's on `nazgul` — that's the only way to see what these containers were actually doing during a crash.** This is the main open thread for whoever picks this up.

## Suggested next steps

1. **Check `nazgul` for existing Prometheus/Grafana/log aggregation** before building anything new — the `monitoring` namespace's bare exporters (`kube-state-metrics`, `node-exporter`) strongly suggest something external is already scraping this cluster (the existing UPS/temperature Grafana dashboard work implies as much). If Loki or similar is already collecting container logs, historical crash reasons for these two pods may still be recoverable there even though kubectl's own record is gone.
2. **If nothing's watching restart rates yet**, this is a concrete argument for adding it. Raw restart count is close to useless as an alert signal — 4,842 accumulated slowly enough over 42 days that nothing ever tripped a threshold, and it took a manual `kubectl` comparison across pods to notice. A rate-based rule catches it same-day instead:
   ```yaml
   - alert: PodRestartingTooOften
     expr: increase(kube_pod_container_status_restarts_total[1h]) > 3
     for: 10m
     labels:
       severity: warning
     annotations:
       summary: "{{ $labels.namespace }}/{{ $labels.pod }} restarted {{ $value }}x in the last hour"
   ```
   (Threshold/`for` chosen loosely — every DaemonSet here restarts once nightly by design via the power-cycle, so tune around that baseline rather than zero.)
3. **A per-node view would have caught this faster than per-pod did.** A Grafana panel or second alert grouping `increase(kube_pod_container_status_restarts_total[1h])` by `node` turns "three separate pods with suspiciously high numbers, noticed by manually diffing kubectl output" into one obvious outlier bar on a chart. Worth having regardless of whether `ipc7`'s specific issue ever gets root-caused, since it generalizes to catching the next node-level problem too.
4. **If/when this actively crash-loops again** (rather than sitting at a stable historical count, as it is right now), grab `kubectl logs --previous` and `kubectl describe pod` *immediately* — this investigation's biggest limitation was that all of that evidence had already aged out by the time anyone looked.

## For context: the IPVS/Cilium/MetalLB decisions this investigation started from

Not new — already fully documented in this repo, cross-referenced here only because it was the starting point:

- **IPVS**: tried, deliberately rejected. Cilium's BPF TC hooks shadow IPVS's netfilter-based virtual servers — NodePorts become unreachable from outside the cluster even though `ipvsadm -Ln` looks correct. Combined with IPVS's deprecation in Kubernetes 1.35, kube-proxy runs in `nftables` mode in production. `experiments/31-ipvs-demo/` is a deliberately-kept-running demo of IPVS's least-connection scheduling, not a leftover from a failed attempt. Full detail: `docs/cilium.md`.
- **Cilium**: replaced Flannel 2026-08-01. Three Pelagos bugs (#484, #483, #492) had to be fixed before it ran cleanly (all fixed by v0.65.73+). A separate, still-open upstream Cilium bug (#43012) misclassifies kubelet health-probe traffic once any NetworkPolicy is present in a namespace; workaround is a `CiliumNetworkPolicy` allowing `world` scoped to probe ports, currently applied to `flux-system`. Full detail: `docs/cilium.md`.
- **MetalLB**: replaced k3s's built-in ServiceLB 2026-06-28, runs in **L2 (ARP) mode**, not BGP — a deliberate choice at 6-node scale. Had its own Pelagos compatibility bug (hostNetwork + `NET_RAW` sandbox handling, #410/#411) before v0.65.40. Full detail: `docs/metallb.md`.
