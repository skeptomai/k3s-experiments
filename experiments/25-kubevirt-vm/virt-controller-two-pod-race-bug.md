# KubeVirt Bug: virt-controller creates two virt-launcher pods per VMI on HA API server deployments

**Affects:** KubeVirt v1.8.4 (and likely earlier/later versions)  
**Severity:** Critical — VMI launch blocked entirely  
**Reproducibility:** 100% on k3s HA (3-node embedded etcd); rare on single-API-server clusters  
**Discovered:** 2026-07-15 on k3s v1.35.5 + KubeVirt v1.8.4 + Pelagos CRI v0.65.50

---

## Summary

On every VMI creation attempt, `virt-controller` creates **two `virt-launcher` pods simultaneously** for a single VMI. `virt-handler` then finds two launcher sockets for the VMI, cannot determine which to use, and blocks indefinitely. The VMI never starts.

The root cause is a race in `virt-controller`'s VMI reconciler: a VMI status update fails with HTTP 409 (Conflict) due to read-after-write inconsistency on a multi-API-server Kubernetes deployment, causing a retry that bypasses the `podExpectations` creation guard and creates a second pod.

---

## Environment

```
Kubernetes:  k3s v1.35.5 (3-node HA, embedded etcd, ipc4/5/6 as control-plane)
KubeVirt:    v1.8.4
CRI:         Pelagos v0.65.50 (custom; confirmed not causal — see below)
API servers: 3 active instances, all serving via kubernetes ClusterIP service (10.43.0.1)
virt-controller replicas: 1 (spec.infra.replicas: 1 in KubeVirt CR)
```

---

## Observed Symptoms

1. Every `kubectl apply` of a VMI creates **two** `virt-launcher` pods:

```
NAME                                    READY   STATUS    AGE
virt-launcher-cirros-test-sjz5c         0/1     Pending   5s
virt-launcher-cirros-test-pb6z6         0/1     Pending   5s
```

2. `virt-handler` logs on the target node:

```
"found more than one virt-launcher socket for vmi cirros-test: [socket1 socket2]"
```

3. VMI stays in `Scheduling` phase forever — never reaches `Running`.

4. Deleting one pod manually does not fix it; `virt-handler` still blocks.

5. The only recovery is to delete both pods and the VMI, then retry — which immediately reproduces the same failure.

---

## Root Cause: Two Concurrent Bugs Composing

### Bug 1: Read-after-write inconsistency triggers a 409 on VMI status update

In a 3-API-server HA deployment, `virt-controller`'s informer (a long-lived watch connection to one API server) can lag behind writes that went to a different API server. When the VMI reconciler:

1. Reads the VMI from the informer cache (stale — missing the annotation write from the previous `execute()` call)
2. Creates pod #1 successfully via the Pods API
3. Calls `updateStatus()` to update VMI status using the stale VMI object (with old `resourceVersion`)
4. Gets HTTP 409 Conflict from the API server (etcd has a newer version)

This is explicitly acknowledged in the Kubernetes API specification:

> *"It is possible for the watch to start at a much older resource version that the client has previously observed, particularly in **high availability configurations, due to partitions or stale caches**."*
> — kubernetes.io/docs/reference/using-api/api-concepts

And for "most recent" reads from the watch cache (k8s v1.31+):

> *"The returned data must be consistent (in detail: served from etcd via a quorum read). For etcd v3.4.31+ and v3.5.13+, Kubernetes v1.31+ serves 'most recent' reads from the watch cache with progress notification to maintain cache consistency."*

In our k3s setup, the kubernetes ClusterIP service actively load-balances across all 3 API servers. A write (VMI annotation) can land on server A while the informer's watch stream is connected to server B. Server B's watch cache has not yet processed the annotation write when the reconciler re-runs — giving it a stale VMI to update.

**This 409 is the correct API server response.** The bug is what happens next.

### Bug 2: `podExpectations` guard bypassed on retry

`virt-controller`'s VMI reconciler uses `podExpectations` (a `UIDTrackingControllerExpectations`) to prevent creating duplicate pods. The guard works correctly under normal conditions: `createPod()` sets `{add:1}`, and subsequent reconcile cycles skip pod creation until that expectation is fulfilled (the pod appears in the informer).

However, when `updateStatus()` returns a 409:
1. `execute()` returns an error and re-queues the VMI key
2. Between the re-queue and the retry (< 30ms), `podExpectations.SatisfiedExpectations(key)` returns **"never recorded"** — as if `{add:1}` was never set
3. `needsSync = true`, `CurrentVMIPod()` returns nil (pod #1 not yet in the informer cache)
4. `createPod()` is called again → pod #2 is created

### Confirmed from logs

Full log sequence from `virt-controller` at the moment of failure (all timestamps `2026-07-15T22:56:05.xxxZ`):

```
.291605  addVMI fires for default/cirros-test
.291642  vmiExpectations set {add:0}          ← lowerVMIExpectation
.291676  podExpectations: "never recorded"    ← first sync, correct (new VMI)
         → needsSync = true
.291730  podExpectations.ExpectCreations{add:1}  ← createPod(sjz5c) called
         [Pod sjz5c API call in flight — ~44ms to complete]

.318379  vmiExpectations set {add:0}          ← lowerVMIExpectation from VMI update event
.320993  vmiExpectations set {add:0}          ← updateStatus() conflict error path
.321034  "reenqueuing default/cirros-test"    ← 409 CONFLICT on VMI status update!
         execute() returns error, Queue.Done(key) called

.321092  podExpectations: "never recorded"    ← BUG: should be {add:1}!
.321120  vmiExpectations: "fulfilled {add:0}"
.321140  pvcExpectations: "never recorded"
.321171  pvcExpectations (inside sync()): "never recorded"
         → needsSync = true, CurrentVMIPod() = nil (sjz5c not in cache yet)
.321411  podExpectations.ExpectCreations{add:1}  ← createPod(pb6z6) called — SECOND POD!

.336250  Pod sjz5c observed by informer → CreationObserved → {add:0}
.342210  Pod pb6z6 observed → CreationObserved → {add:-1}  ← goes negative
```

Two `SuccessfulCreate` events recorded in virt-controller's event history:
```
SuccessfulCreate  virt-controller  Created virtual machine pod virt-launcher-cirros-test-sjz5c
SuccessfulCreate  virt-controller  Created virtual machine pod virt-launcher-cirros-test-pb6z6
```

### Confirmed: `DeleteExpectations` called on transient cache miss

Debug logging added to `execute()` confirmed the mechanism. The `podExpectations` key goes to "never-recorded" via **path 1** in `execute()`:

```go
// pkg/virt-controller/watch/vmi/vmi.go — execute()
obj, exists, err := c.vmiIndexer.GetByKey(key)
if !exists {
    c.podExpectations.DeleteExpectations(key)  // ← CONFIRMED: this fires
    c.vmiExpectations.DeleteExpectations(key)
    c.cidsMap.Remove(key)
    return nil
}
```

When the informer's watch connection drops and reconnects to a different API server in the HA cluster, the informer performs a re-list. During this re-list cycle, the `cache.ThreadSafeStore` can emit a `cache.DeletedFinalStateUnknown` (tombstone) event for a VMI that **still exists** in etcd. The tombstone causes:

1. The VMI to be **removed from `c.vmiIndexer`**
2. `deleteVirtualMachineInstance()` to enqueue the VMI key
3. `execute(key)` to find `!exists` and call `DeleteExpectations(key)` → expectations erased

Moments later, the re-list completes and the VMI reappears via an ADD event:
4. `execute(key)` fires with `never-recorded` (expectations were cleared) → `needsSync=true`
5. `CurrentVMIPod()` returns nil (pod #1 also not yet reflected in stale informer cache)
6. `createPod()` called → **pod #2 created**

This is distinct from (but composes with) the 409 Conflict: both the 409 retry path and the re-list tombstone path lead to `DeleteExpectations` being called at the wrong time. The tombstone path is the more reproducible trigger in k3s HA.

### Code locations (KubeVirt v1.8.4)

| File | Lines | Relevance |
|------|-------|-----------|
| `pkg/virt-controller/watch/vmi/vmi.go` | `execute()` function | Main reconcile loop; `needsSync` check; `DeleteExpectations` on `!exists` |
| `pkg/virt-controller/watch/vmi/lifecycle.go` | `createPod()` ~L1034 | Sets `podExpectations.ExpectCreations(key, 1)` |
| `pkg/virt-controller/watch/vmi/lifecycle.go` | `updateStatus()` ~L271 | On conflict: resets `vmiExpectations`, returns error |
| `pkg/controller/expectations.go` | `SetExpectations()` | **Replaces** existing entry — `ExpectCreations(key,1)` after a `SetExpectations(key,0,0)` would reset |
| `pkg/controller/controller.go` | `CurrentVMIPod()` ~L323 | Returns most-recent pod by timestamp from indexer |
| `pkg/virt-controller/leaderelectionconfig/config.go` | `DefaultRetryPeriod = 2s` | Lease renewal period |

---

## Why This Only Manifests on HA Deployments

**Single API server (standard KKS, GKE, EKS, kubeadm):**
- All reads and writes go through the same server
- The informer's watch stream is on the same server as the write path
- Watch cache lag is microseconds
- VMI annotation write propagates to informer cache before the reconciler re-runs
- `updateStatus()` uses a current `resourceVersion` → no 409 → no retry → single pod

**3-node HA k3s (our setup):**
- The `kubernetes` ClusterIP service (10.43.0.1) round-robins across ipc4/5/6 API servers
- Write requests (VMI annotation, status update) land on different servers than the informer's watch stream
- Watch cache lag can be significant when write and watch servers differ
- `updateStatus()` uses a stale `resourceVersion` → 409 → retry → second pod
- **Happens on every VMI creation attempt** (100% reproducible)

**Confirmed NOT causal:**
- **Custom CRI (Pelagos):** Pod cleanup latency measured at <1.2s; pods were created simultaneously within the same second. Pelagos contributes no timing difference that would affect pod creation.
- **virt-controller lease conflicts:** A separate anomaly (91.5% of lease renewal fast-path attempts fail with 409, also due to HA API server load balancing). Not causal for the two-pod race, but indicates the same underlying consistency issue.

---

## API Server Consistency Background

The Kubernetes API specification defines `resourceVersion` semantics for optimistic concurrency. The 409 Conflict response is correct and expected. The issue is that `virt-controller` does not handle this conflict safely.

Controllers following the Kubernetes controller pattern are expected to:
- Re-read the object before updating (which virt-controller does — from the informer cache)
- Handle 409 conflicts by re-queuing

The gap: re-reading from the informer cache is not a "consistent read" in the Kubernetes API spec sense. The informer cache is eventually consistent with etcd via asynchronous watch. In HA deployments, the watch cache on server B may lag behind a write committed to server A. The spec-correct approach to avoid this race is to use `resourceVersionMatch: NotOlderThan` on GETs, but informers do not do this — they trade consistency for performance, which is acceptable for reconcile loops that handle conflicts gracefully. The bug is that `virt-controller`'s conflict handling in this specific code path is not safe.

**Relevant KEP / upstream discussion:**
- [KEP-2340: Consistent reads from cache](https://github.com/kubernetes/enhancements/issues/2340) — addresses this for k8s v1.31+ via progress notifications, but does not eliminate cross-server watch cache lag in HA setups
- virt-controller uses `k8s.io/client-go v0.34.2`

---

## Fix

**Root cause:** `DeleteExpectations(key)` is called in `execute()` when `c.vmiIndexer.GetByKey(key)` returns `!exists`, without confirming the VMI is truly gone from the API server. During informer re-list (triggered by watch reconnection between HA API servers), a tombstone DELETE event can temporarily remove a live VMI from the local cache.

**Fix:** Before calling `DeleteExpectations` in the `!exists` branch, perform a live GET against the API server to confirm the VMI is truly absent. If the API server returns 200 (VMI still exists), requeue without clearing expectations.

```go
// In execute(), the !exists branch — pkg/virt-controller/watch/vmi/vmi.go
if !exists {
    ns, name, splitErr := cache.SplitMetaNamespaceKey(key)
    if splitErr != nil {
        return splitErr
    }
    _, apiErr := c.clientset.VirtualMachineInstance(ns).Get(
        context.Background(), name, v1.GetOptions{})
    if apiErr == nil {
        // VMI still exists in API server; local cache is transiently stale.
        // Requeue without clearing expectations so the next sync uses correct state.
        log.Log.Infof("VMI %s not in local cache but exists in API server (stale cache), requeueing", key)
        return fmt.Errorf("VMI %s not in local cache but exists in API server, requeueing", key)
    }
    if !k8serrors.IsNotFound(apiErr) {
        return apiErr
    }
    // VMI confirmed gone — safe to clear expectations
    c.podExpectations.DeleteExpectations(key)
    c.vmiExpectations.DeleteExpectations(key)
    c.cidsMap.Remove(key)
    return nil
}
```

**Tradeoffs:**
- Adds one API GET per `execute()` call when the local cache misses the VMI — this is the exceptional case (cache miss), not the hot path
- The requeue triggers an exponential backoff, so transient stale-cache misses converge quickly once the informer re-lists
- Does not affect the 409 conflict path directly, but that path doesn't cause `!exists` — it returns an error before reaching the `DeleteExpectations` call

**Alternative considered:** Verify pod existence via live API in `sync()` before `createPod()`. Rejected: this would add an API call to the hot path (every VMI sync). The `!exists`-guard fix is more targeted.

**PR:** https://github.com/kubevirt/kubevirt/pull/18475 (skeptomai/kubevirt@fix/virt-controller-two-pod-race)

---

## Workaround

None that fully resolves the issue without intervention. Manual workaround per VMI launch attempt:

```bash
# After VMI creation, delete the duplicate pod immediately
kubectl -n default get pods -l kubevirt.io/created-by=<vmi-uid> 
kubectl -n default delete pod <second-pod-name>
```

This is not practical as the duplicate is created within milliseconds and `virt-handler` may already be blocked.

---

## References

- KubeVirt source: https://github.com/kubevirt/kubevirt (Apache-2.0)
- KubeVirt v1.8.4 tag: https://github.com/kubevirt/kubevirt/tree/v1.8.4
- Kubernetes API concepts — resourceVersion: https://kubernetes.io/docs/reference/using-api/api-concepts/#resource-versions
- Kubernetes API concepts — HA watch semantics: https://kubernetes.io/docs/reference/using-api/api-concepts/#semantics-for-watch
- client-go leaderelection: https://github.com/kubernetes/client-go/blob/v0.34.2/tools/leaderelection/leaderelection.go
- Related: `pkg/virt-controller/watch/vmi/vmi.go`, `lifecycle.go`, `pkg/controller/expectations.go`
