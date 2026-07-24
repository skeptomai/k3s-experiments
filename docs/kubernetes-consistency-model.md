# Kubernetes Consistency Model

Notes on how reads and writes flow through the Kubernetes stack, and where
consistency breaks down. Useful context when debugging controller behavior,
HA failover issues, and stale-cache bugs.

## The stack

```
etcd cluster  →  API server watch cache  →  controller informer cache
(consistent)     (eventually consistent)     (briefly inconsistent on reconnect)
```

### etcd

etcd uses the Raft consensus algorithm. A write does not succeed until a
majority of members acknowledge it. The leader applies the write only after
quorum is reached, so by the time a client receives a success response, the
write is committed and no member will serve a read that contradicts it.
Read-after-write is guaranteed at the etcd layer.

### API server watch cache

The API server does **not** consult etcd on every read. It maintains its own
in-memory cache, populated by a watch it holds against etcd. This cache is
eventually consistent with etcd — there is a lag, and different API servers
in an HA setup can be at different resource versions at the same moment,
depending on how far behind their respective watches are.

The API server does offer an escape hatch: passing a specific `resourceVersion`
(or an empty string rather than `"0"`) can force a quorum read from etcd,
bypassing the cache. `kubectl get` uses this in some modes. But this is not
the default path.

### Controller informer cache

Controllers (virt-controller, kube-controller-manager components, etc.) do not
read from the API server on every reconcile. They maintain a local in-memory
cache — the **informer cache** — populated by a watch stream from the API
server. Reconcile loops read from this local cache, not from the API server.

The informer cache is fed from the API server cache, which is fed from etcd.
So there are two layers of eventual consistency between what etcd has committed
and what a controller sees.

## What controllers do

A **controller** watches a set of Kubernetes resource types and drives actual
state toward desired state. The reconcile loop:

1. Is woken by a watch event (object added, modified, or deleted).
2. Reads the current state of relevant objects from the **local informer cache**.
3. Compares actual state to desired state.
4. Takes action (creates, updates, or deletes objects via the API server).

Controllers also run periodic re-syncs (a full relist on a timer, typically
every 10–30 minutes) to catch anything the watch stream missed.

**Expectations** are a common bookkeeping pattern: before creating a child
object (e.g. a pod for a VMI), the controller records "I expect +1 pod." It
won't create another until that expectation is satisfied or times out,
preventing duplicate creation under normal load.

## Where things go wrong: watch stream reconnect

When a controller's watch connection drops and reconnects — potentially to a
different API server in an HA cluster — the client library resyncs:

1. It relists the current state from the (new) API server.
2. It diffs the relist result against what it had in the local cache.
3. Anything in the local cache that didn't appear in the relist is synthesized
   as a **tombstone DELETE** — a fake deletion event representing "this object
   was gone by the time we reconnected."

Tombstoning is conservative by design: it's better to fire a spurious delete
than to silently hold a stale object in cache forever. But it misfires when:

- The relist lands on an API server that is slightly behind the one the watch
  was previously connected to (lag between API server caches).
- A live object falls outside the relist's resource version window and looks
  absent to the new server momentarily.

The controller then handles the tombstone DELETE as if the object were really
gone, which can clear expectations and trigger duplicate work on the next
reconcile.

## The KubeVirt two-pod race (kubevirt/kubevirt #18475)

Concrete example of the above in our cluster.

**Setup:** HA cluster with kube-vip floating VIP across three API servers
(ipc4–6). virt-controller holds a watch on VirtualMachineInstance objects.

**Race:**
1. virt-controller creates a virt-launcher pod for VMI `cirros-test`.
   Expectations recorded: +1 pod expected.
2. Watch connection drops during a VIP failover; reconnects to a different
   API server.
3. `cirros-test` appears absent in the relist window → tombstone DELETE fired.
4. virt-controller's `!exists` branch handles the DELETE, calls
   `DeleteExpectations` — wiping the record that a pod was already created.
5. Next reconcile: VMI exists, no expectations, no pod tracked → creates a
   second virt-launcher pod. Two pods now compete for the same VMI.

**Fix:** In the `!exists` branch, before clearing expectations, do a live GET
to the API server to confirm the VMI is actually gone. If it comes back, the
tombstone was spurious — skip the deletion logic.

Note: a live GET to the API server is better than trusting the local cache,
but it is still not a quorum read from etcd. It reduces the window but does
not eliminate it entirely.
