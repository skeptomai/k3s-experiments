# Post-Mortem: etcd Under Pressure — ipc5 GC Death Spiral

**Date:** 2026-07-17  
**Duration:** ~3 hours of degraded service, ~30 min of full ipc5 outage  
**Resolution:** Full OS reboot of ipc5  
**Severity:** High — vault crash-looping, spire-agent cycling, control-plane node intermittently NotReady

---

## Summary

A routine Pelagos v0.65.60 deployment triggered a write storm that caused etcd on ipc5
to enter a goroutine accumulation feedback loop. The k3s process heap grew from a normal
~650MB to 7.6GB, at which point Go's garbage collector was spending more time scanning
the heap than doing useful work. This manifested as etcd raft reads taking 10–18 seconds
instead of <5ms, causing the ipc5 kubelet to miss heartbeat deadlines, ipc5 to go
NotReady intermittently, and pods scheduled there (vault-0, speaker-nrfhn,
spire-agent-n9v8m) to crash-loop.

Restarting k3s alone did not help — the new process immediately re-accumulated goroutines
because the pods crash-looping on ipc5 kept generating new write traffic. A full OS
reboot was required to reset the heap, clear all TCP/watch connections, and break the
feedback loop. After reboot: k3s RSS 653MB, load 0.36, zero slow etcd queries, all pods
recovered within 90 seconds.

---

## Timeline

| Time | Event |
|------|-------|
| ~14:00 | Pelagos v0.65.60 deployed across all 6 nodes; all pods on each node restarted in sequence |
| ~15:00 | ipc5 etcd latency begins climbing; first NotReady events appear |
| ~16:00 | vault-0 (on ipc5) enters CrashLoopBackOff; orphan vault process (Pelagos #457 non-hostNetwork leak) holding BoltDB flock |
| ~16:30 | Orphan killed manually; vault-0 unsealed; briefly recovers |
| ~17:00 | ipc5 k3s at 1129% CPU, load 14+; etcd reads taking 10–13s; k3s restarted |
| ~17:01 | k3s restart provides no relief; new process at 848% CPU within 2 minutes; RSS already 7.6GB |
| ~17:30 | ipc5 fully rebooted via `sudo reboot`; machine hangs mid-shutdown (did not POST cleanly) |
| ~18:07 | Hard power cycle via KVM; ipc5 POST and boot |
| ~18:52 | ipc5 Ready; k3s RSS 653MB, load 0.6, 0 slow etcd queries |
| ~18:53 | vault-0 1/1 Running (unsealed from raft), speaker 1/1, spire-agent 1/1 — all without intervention |

---

## Root Cause: The etcd Goroutine Death Spiral

### What etcd does for linearizable reads

etcd provides linearizable reads by default, which Kubernetes requires for correctness
(the scheduler cannot act on stale node state). For a follower to serve a linearizable
read, it uses the **read-index** mechanism:

1. Send a read-index ping to the raft leader: *"what is your current commit index?"*
2. Wait until the local apply index catches up to that commit index
3. Serve the read from the local b-tree

Under normal conditions this round-trip takes <5ms on a LAN.

### What happens under write pressure

The Pelagos deployment restarted all pods on all 6 nodes in sequence. Each pod restart
generates a burst of etcd writes: pod status transitions, container state updates,
endpoint changes, lease renewals, and events. Compounding this:

- vault-0 crash-looping: ~1 restart per 5 minutes × ~50 writes per restart
- spire-agent crash-looping: 711 restarts over 8 days, accelerating during the incident
- speaker-nrfhn crash-looping: 109 restarts over 12 hours
- Multiple force-deletes with `--grace-period=0`
- All six kubelets, Flux controllers, KubeVirt controllers, cert-manager, MetalLB — all
  reconnecting their watches simultaneously after each NotReady period

The raft leader (whichever of ipc4/5/6 held the role) was continuously committing new
entries. A follower's read-index response kept returning an ever-advancing commit index.
Each goroutine waiting for the apply index to catch up found the target moving away from
it. New request goroutines arrived faster than old ones completed.

### The feedback loop

```
write storm
    → goroutines pile up waiting for raft read-index
        → each goroutine sends its own read-index ping
            → leader gets thousands of read-index pings on top of write load
                → leader slows down
                    → goroutines wait longer
                        → more goroutines arrive
                            → Go heap grows (each goroutine: ~8KB stack + objects)
                                → GC must scan larger heap → GC pauses grow
                                    → GC pauses block goroutine scheduling
                                        → raft responses delayed further
                                            → goroutines wait even longer
                                                → (repeat)
```

The critical property of this loop: **etcd has no backpressure**. It accepts every
incoming connection and spawns a goroutine for every request regardless of current load.
There is no circuit breaker, no 503 when the read-index backlog exceeds a threshold, no
admission control. The system just accepts work until it cannot function.

### Why k3s restart alone didn't help

The new process started with a clean heap (~650MB). But:

1. All watch clients (6 kubelets, Flux, KubeVirt, etc.) immediately reconnected
2. Each reconnect triggers a full list-then-watch, which reads every object of that type
   from etcd
3. Dozens of controllers reconnecting simultaneously = hundreds of concurrent list
   operations = goroutines accumulate immediately
4. The crash-looping pods on ipc5 kept generating writes
5. Within 2 minutes the heap was back to ~7GB and the cycle had restarted

### Why a full OS reboot fixed it

1. **Heap wiped to zero** — k3s starts with 653MB RSS, no GC pressure
2. **All TCP connections torn down** — watch clients reconnect staggered over time
   (not simultaneously), spreading the list-then-watch load over ~30s instead of
   instantaneously
3. **Crash loops on ipc5 reset** — speaker and spire-agent started cleanly on the
   fresh node, eliminating the write traffic they were generating
4. **No accumulated goroutine backlog** — the first read-index ping gets a response
   in <5ms, completing immediately rather than queuing behind thousands of others

Post-reboot trajectory observed:

| Time since boot | k3s RSS | Load (1m) | Slow etcd/20s |
|----------------|---------|-----------|----------------|
| 0:01 | 653MB | 0.89 | 0 |
| 0:02 | 655MB | 0.76 | 0 |
| 0:03 | 670MB | 0.51 | 0 |
| 0:04 | 671MB | 0.36 | 0 |

All pods running, no slow queries, heap stable under 700MB.

---

## Contributing Factor: Pelagos #457 Non-hostNetwork Process Leak

The orphan vault process holding the BoltDB flock was caused by Pelagos bug #457 — when
`pelagos-cri` restarts, re-adopted container processes from `state.json` are not killed
by `StopPodSandbox`. The hostNetwork case was fixed in v0.65.59 (the original symptom was
ports staying bound), but the non-hostNetwork case was not — and today proved it IS
harmful: the orphan held an OS-level `flock()` on `/var/lib/vault-data/vault.db` for
hours, preventing any new vault container from opening the file.

This was filed as a separate issue (#457 reopened) with the vault BoltDB evidence.

---

## Why etcd Is Structurally Prone to This

etcd is the Kubernetes control plane store. It was designed alongside Kubernetes at
Google/CoreOS and the apiserver speaks its watch API natively. This makes it difficult
to replace.

The specific design weaknesses exposed here:

- **No backpressure / no load shedding** — accepts every request regardless of current
  queue depth. A well-designed system would return 503 when the read-index backlog
  exceeds a threshold and let clients back off.
- **Goroutine-per-request in Go** — works well in steady state, catastrophic under
  bursty load when all goroutines block on the same bottleneck. The goroutines themselves
  add to the load they're waiting on.
- **GC amplification** — large heaps from goroutine accumulation trigger long GC pauses,
  which further delay raft responses, which cause more goroutines to accumulate.
- **Failure amplifier placement** — etcd is on the critical path for kubelet heartbeats.
  Slow etcd → kubelet misses deadline → node goes NotReady → pods evicted → more etcd
  writes → even slower etcd. The system is anti-resilient exactly when it needs to be
  most resilient.
- **Write storm from cluster churn is a positive feedback loop** — the worse the cluster
  state, the more etcd writes are generated, the worse etcd performs, the worse the
  cluster state.

### Alternatives

**kine + PostgreSQL**: k3s supports replacing etcd entirely with a SQL backend via the
`kine` shim. PostgreSQL uses a connection pool with configurable max connections — under
write pressure it queues and throttles cleanly rather than spiraling. Reads are served
from WAL-consistent snapshots without a raft round-trip. Substantially more operationally
mature failure modes. Trade-off: adds a PostgreSQL cluster to the ops surface.

**TiKV** (used by TiDB, written in Rust): uses async/await instead of goroutines,
avoiding the Go GC amplification problem. Has proper follower reads that bypass the
read-index round-trip entirely for non-linearizable queries. No Kubernetes integration
currently.

For this cluster, kine+PostgreSQL is worth evaluating as a future migration path. The
current embedded etcd is adequate under normal conditions but has demonstrated it will
spiral under deployment churn — which is exactly when you need the control plane to be
most stable.

---

## Remediation Applied

1. Killed orphan vault processes on ipc5 and ipc6 (Pelagos #457 non-hostNetwork leak)
2. Unsealed vault-0, vault-1, vault-2 via Shamir HTTP API from ipc4
3. Restarted k3s on ipc5 (insufficient — heap re-accumulated within 2 minutes)
4. Hard power cycled ipc5 (initial `sudo reboot` hung mid-shutdown)
5. Unsealed vault-0 after reboot (vault-1/2 maintained quorum; vault-0 unsealed from raft)
6. Bumped node-exporter memory limit 64Mi → 192Mi (pre-existing OOMKill, unrelated)

---

## Pelagos Issues Filed / Updated

| Issue | Status | Summary |
|-------|--------|---------|
| #461 | Closed | RuntimeDefault seccomp EINVAL — confirmed fixed in v0.65.60 |
| #457 | Reopened | Non-hostNetwork process leak causes file lock issues (vault BoltDB) |
| #466 | New | container.rs: no-limit pods get memory.max=16MB instead of unlimited (shadow deploy regression) |

---

## Alerting Gaps (see `alerting-improvements.md`)

The original alert was `KubePodCrashLoopBackOff` with no pod name, namespace, or node
in the alert body. By the time it fired, the root cause was several layers removed from
any individual pod crash loop. See the alerting improvements doc for proposed additions.
