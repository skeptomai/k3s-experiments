# How Resource Limits Work

## CPU Requests

**Where it's observed:** The scheduler only. CPU requests have zero enforcement at
runtime — they're accounting entries. When a pod is placed, the scheduler subtracts
the request from the node's "available" pool. That's it.

**How it's enforced at runtime:** Through cgroups v2 `cpu.weight`. Each container gets
a weight proportional to its request (100m → weight ~10, 1000m → weight ~100). Weight
only matters under contention — if the node is idle, every container gets as much CPU
as it wants regardless of requests. When multiple containers are competing for CPU, the
kernel's CFS scheduler gives each container CPU time in proportion to its weight.
Requests are a floor under contention, not a hard reservation.

---

## CPU Limits

**Where it's enforced:** cgroups v2 `cpu.max` — the Linux CFS bandwidth controller.

The limit is expressed as a quota/period pair. A limit of `250m` becomes `25000 250000`
— meaning this container may use at most 25ms of CPU time in every 250ms window. If the
container burns through its quota before the window expires, the kernel throttles it: it
goes to sleep until the next period, even if CPUs are sitting idle.

This is why CPU limits are controversial in production. A container can be throttled to
near-zero even on an idle node because it happened to use its quota in a burst at the
start of the window. Many operators set CPU requests but deliberately omit CPU limits
for latency-sensitive workloads.

---

## Memory Requests

**Where it's observed:** The scheduler only, same as CPU requests. There is no kernel
mechanism that enforces a memory request floor. A container requesting 64Mi can actually
allocate 1GB if the node has it and no limit is set. The request is purely a scheduling
hint — "please put me on a node that has at least this much free."

---

## Memory Limits

**Where it's enforced:** cgroups v2 `memory.max`. This is hard kernel enforcement.

Every byte of memory allocated by processes in the cgroup is tracked. When the cgroup's
total allocation hits `memory.max`, the next allocation triggers the kernel's OOM killer.
The OOM killer scores each process in the cgroup and kills the highest scorer — in a
single-container pod that's always the container's main process. Hence exit code 137
(SIGKILL).

The sequence from this experiment:

```
stress asks for 128M of memory
  → mmap() / malloc() calls succeed initially (lazy allocation)
  → kernel starts faulting pages in as stress actually writes to them
  → cgroup memory counter hits 64Mi (the limit)
  → OOM killer fires
  → stress process receives SIGKILL
  → container exits 137
  → pod status → OOMKilled
```

The OOM kill happens in the kernel, inside the page fault handler, at the moment the
cgroup would exceed `memory.max`. There's no grace period, no SIGTERM — it's
instantaneous.

---

## Scheduler: Unschedulable Pods

**Where it's enforced:** The kube-scheduler, before the pod ever touches a node.

The scheduler maintains a view of each node's **allocatable** resources — total capacity
minus what's already been requested by running pods. When a new pod arrives, the scheduler
tests every node:

```
node.allocatable - sum(existing pod requests) >= new pod requests?
```

If no node passes, the pod goes into the pending queue and the scheduler emits a
`FailedScheduling` event. It re-evaluates periodically — if a node gains capacity (pods
leave, a node is added), the pending pod will eventually be placed.

The critical point: **the scheduler works entirely off requests, not actual usage.** A
node running at 5% actual CPU but with 90% of its CPU requested is considered full by
the scheduler. This is why setting accurate requests matters:

- **Over-requesting** wastes schedulable capacity — nodes look full when they aren't
- **Under-requesting** causes pods to land on nodes that can't actually sustain them under load

---

## Summary

| | Requests | Limits |
|-|---------|--------|
| **CPU** | Scheduler accounting + cgroups `cpu.weight` (contention only) | cgroups `cpu.max` — CFS quota, container throttled not killed |
| **Memory** | Scheduler accounting only — no runtime enforcement | cgroups `memory.max` — OOM killer, instantaneous SIGKILL |
| **Enforced by** | kube-scheduler (placement) + kernel (CPU weight) | Linux kernel cgroups v2 |
| **Pod survives breach?** | N/A | CPU: yes (throttled) — Memory: no (OOMKilled) |
