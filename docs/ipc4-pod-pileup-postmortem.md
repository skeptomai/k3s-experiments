# ipc4 Pod Pileup — 2026-08-21 Postmortem

## Summary

Pushover alert: the 2026-08-20 21:00 `night-off` shutdown failed. Investigation
turned up two separate, compounding issues — a KubeVirt drain failure that
caused that specific alert, and a much larger structural problem (43 of the
cluster's ~90 pods concentrated on a single node, ipc4) that the alert only
incidentally surfaced.

## What actually happened

**The shutdown failure**, root-caused directly from `shutdown-cluster.sh`'s
logs: draining ipc4 timed out evicting `virt-api`/`virt-controller` — both
replicas of each happened to be co-located on ipc4 (no anti-affinity), so
draining that one node required evicting all 4 at once. The PDB
(`minAvailable: 1`) only permits one disruption at a time, and replacements
had no guarantee of landing elsewhere. Drain hit its 2-minute global timeout,
`shutdown-cluster.sh` aborted **before** the power-off step, and the cluster
just stayed up all night — not a runaway process, just skipped cooldown.

**The pileup**, found while investigating why ipc4 was running hotter than
its HA peers (57°C → 63°C → 67°C CPU over successive days): 43 pods on ipc4
vs. 5-9 on each of the other five nodes. Root cause, confirmed against
`shutdown-cluster.sh`/`morning-on.sh` directly: all six nodes get cordoned
*before* any draining starts, so every reschedulable pod goes `Pending`
cluster-wide during the shutdown window. `morning-on.sh` then uncordons all
six back-to-back, and that whole batch schedules in one wave. Several
platform Deployments (cert-manager, MetalLB controller, and others) had zero
CPU/memory requests set, so the scheduler had no resource signal to spread
that wave on and fell back to weaker tie-breakers like image locality —
which favored ipc4, since it had run these before. Self-reinforcing across
every *successful* nightly cycle, not just failures.

## Fixes

1. **KubeVirt anti-affinity** (`manifests/kubevirt/kubevirt-cr.yaml`) —
   required pod anti-affinity so `virt-api`/`virt-controller` replicas can
   never co-locate on one node again.
2. **Cordoned + drained ipc4** once by hand to force redistribution and
   validate the anti-affinity fix — confirmed clean (no stuck evictions,
   unlike the failed nightly run). ipc4 went 43 → 9 pods.
3. **Resource requests added** to every Deployment found with none: 3x
   cert-manager, MetalLB controller, local-path-provisioner, authentik
   (server + worker), tailscale-operator, traefik, nfs-subdir-provisioner,
   and the `https-demo` experiment.
4. **Two components brought under GitOps tracking** that had none at all:
   - `traefik` — k3s's own bundled addon; tracked via `HelmChartConfig`
     (the mechanism k3s itself reads), not a competing Flux `HelmRelease`.
   - `nfs-subdir-external-provisioner` — was a bare, untracked
     `helm install` from 2026-06-02. Added `HelmRepository` + `HelmRelease`
     matching its live version/values exactly, adopted cleanly (Helm release
     history shows an upgrade, not a reinstall; pod rolled with 0 disruption
     to PVC provisioning).

A recurring gotcha while doing (3): **`helm upgrade succeeded` and
`helm get values` showing your value both mean "Helm accepted the input,"
never "the chart's templates actually used it."** Caught this concretely
twice — tailscale-operator's chart documents a top-level `resources: {}` key
that doesn't template into the Deployment at all (real path:
`operatorConfig.resources`), and traefik's own already-in-use
`deployment.podAnnotations` value misleadingly suggested `deployment.resources`
when the actual key is top-level `resources:`. Both were only caught by
extracting the real chart tarball and reading `templates/deployment.yaml`
directly, then verifying the **rendered** Deployment object, not trusting
Helm's own success signal.

## Cluster hygiene takeaways

1. **Resource requests as a default habit, not a retrofit.** Every gap here
   existed because something was added without them. Treat it as a checklist
   item when adding anything to `manifests/`, not a periodic audit.
2. **Don't let `helm install`/`kubectl apply` happen outside the repo.**
   nfs-subdir-provisioner sat untracked for months; nothing but a manual
   cross-check of live Helm releases against Git would have caught it.
3. **Verify against the rendered object, not the tool's success signal** —
   for any Helm-managed config change, `kubectl get ... -o jsonpath` the live
   object before considering it done.
4. **Treat a "shutdown failed" alert as a real incident, not routine
   noise** — the failure mode here was silent and self-reinforcing; only
   noticed via a rising temperature trend, not the alert itself explaining
   the real problem.
5. **Stale Flux dependency-readiness state after a mass reconcile** is
   harmless and self-resolving (`flux reconcile kustomization <name>` clears
   it instantly) — recognize it on sight so it isn't mistaken for a real
   failure.
