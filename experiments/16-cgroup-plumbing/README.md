# Experiment 16: Pelagos Cgroup Plumbing Verification

## What this verifies

This is a Pelagos runtime verification experiment, not a Kubernetes learning experiment. It confirms that the full cgroup plumbing chain works end-to-end for CRI-managed containers:

```
k3s kubelet
  → passes cgroup_parent to CRI CreateContainer RPC
    → pelagos-cri passes --cgroup-parent to pelagos run
      → pelagos places container in the kubepods/ cgroup hierarchy
        → cgroup_name written to state.json
          → ContainerStats CRI RPC reads usageCoreNanoSeconds from cgroup
            → kubelet /stats/summary has per-container CPU stats
              → metrics-server serves kubectl top pod
                → HPA can compute CPU utilization
```

If any link in this chain is broken, HPA silently fails with `FailedGetResourceMetric`.

## Checks performed

For each of the 3 pods (one per node):

1. **`cgroup_name` is non-null** — `pelagos container inspect` shows `cgroup_name` starting with `kubepods/`. Confirms k3s is passing `cgroup_parent` and Pelagos is using it.

2. **cgroup exists in the filesystem** — `/sys/fs/cgroup/.../<container-id>` is present on the pod's node. Confirms the container is actually in the correct cgroup hierarchy, not just that the name was recorded.

3. **`usageCoreNanoSeconds` is non-zero** — kubelet `/stats/summary` shows accumulating CPU for the container. Confirms the cgroup read is working and metrics-server can compute a rate.

## Why this matters

Pelagos issue [#327](https://github.com/pelagos-containers/pelagos/issues/327) tracked a regression where `usageCoreNanoSeconds` returned 0 for all CRI-managed containers, breaking HPA. The fix (v0.65.28) implemented the cgroup_name path. This experiment is the permanent regression test for that fix.

The fallback path (reading from `/proc/{pid}/stat` when `cgroup_name` is None) does not produce accumulating `usageCoreNanoSeconds` values — it only produces instantaneous readings, which metrics-server cannot use for rate computation.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `cgroup-verify` namespace |
| `deployment.yaml` | 3-replica nginx, one pod per node via topologySpreadConstraints |
