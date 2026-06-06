# Experiment 17: Container Memory Stats Verification

## What this verifies

Pelagos issue [#328](https://github.com/pelagos-containers/pelagos/issues/328): CRI `ContainerStats` was reporting the memory RSS of the Pelagos **launcher process** (~1.25MB) rather than the cgroup total. Every container showed ~1Mi in `kubectl top pod` regardless of actual workload size.

Fixed in v0.65.30 by reading `memory.current` from the cgroupv2 hierarchy instead of `/proc/<pid>/status` of the launcher PID.

## What you'll observe

- A pod that allocates ~20MB of memory at startup
- `kubectl top pod` reporting a realistic memory value (>10Mi)
- `workingSetBytes` in the kubelet `/stats/summary` matching the cgroup's `memory.current`

## The bug

Before v0.65.30, `pelagos container inspect` exposed `pid` as the Pelagos launcher process. ContainerStats read VmRSS from that PID (~1.25MB), not from the cgroup total:

```
cgroup PIDs:
  744694 (pelagos launcher):  1,260 kB  ← what ContainerStats incorrectly reported
  744695 (coredns workload): 59,288 kB  ← actual workload, ignored
```

The fix reads `/sys/fs/cgroup/<cgroup_name>/memory.current` directly — the kernel-maintained cgroup total, which includes all processes in the container.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `memstats-demo` namespace |
| `deployment.yaml` | busybox pod that allocates ~20MB and holds it |
