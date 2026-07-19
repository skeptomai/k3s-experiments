# Platform Overhead

An investigation into why an idle cluster shows 11,000+ goroutines and ~650 MB of heap
on the control-plane node that holds the kube-vip VIP.

## What triggered this

ipc5 showed ~11,000 goroutines and a ~650 MB heap, climbing. The other control-plane
nodes (ipc4, ipc6) showed roughly half that. Concern: etcd falling behind.

## What the numbers actually mean

Goroutines and watch connections track almost exactly together:

| Node | Goroutines | Active WATCH connections | Heap |
|------|-----------|--------------------------|------|
| ipc5 | 11,013 | 444 | ~652 MB |
| ipc4 | 6,271 | 245 | ~445 MB |
| ipc6 | 5,572 | ~similar to ipc4 | ~368 MB |

Ratio of watches (444/245 = 1.81×) matches ratio of goroutines (11k/6.3k = 1.75×).
The goroutines are watch-connection goroutines, not a leak.

ipc5 had double the watches because it held the kube-vip VIP (`192.168.88.58`). Every
controller that connects to the HA endpoint lands on ipc5. ipc4 and ipc6 only handle
controllers that happened to connect to their individual IPs.

## etcd was fine

Despite appearances, etcd showed no problems at all:

- `etcd_server_proposals_pending`: 0
- `etcd_server_slow_apply_total`: 0
- `etcd_server_slow_read_indexes_total`: 0
- `etcd_server_has_leader`: 1
- DB size: ~23 MB (tiny)
- Backend commit p99: ~4 ms (fine)

The Go heap was large because Go does not run GC aggressively when there is 28 GB of
free RAM. The allocator sits at a high watermark until memory pressure forces collection.

## Where the watches come from

An "idle" Kubernetes cluster is not idle at the API server. Every controller holds a
persistent WATCH open on every resource type it manages, so it can be notified of
changes immediately. On this cluster, those controllers are:

| Component | Pods | Notes |
|-----------|------|-------|
| KubeVirt | 12 | virt-operator, virt-api, virt-controller, virt-handler ×6; watches 19 CRD types |
| SPIRE | 7 | server + agents + controllers |
| Monitoring | 7 | Prometheus, Grafana, Alertmanager |
| MetalLB | 7 | controller + speaker per node |
| kube-system | 7 | Traefik, CoreDNS, kube-vip, etc. |
| Flux | 4 | source/kustomize/helm/notification controllers |
| Vault | 3 | 3-node HA Raft cluster |
| cert-manager | 3 | controller, cainjector, webhook |
| Tailscale | 2 | operator |
| local-path-storage | 1 | |

Total: 54 pods of infrastructure, to run 1 application pod (`gruesome`).

## Why KubeVirt specifically is heavy

KubeVirt has four components with distinct roles:

- **virt-operator** (2 replicas) — lifecycle manager; installs, upgrades, and configures
  the rest of KubeVirt. Watches KubeVirt's own CRDs to know when to reconcile.
- **virt-api** (2 replicas) — webhook/admission server that extends the Kubernetes API
  with VM-specific validation and mutation. Every kubectl operation touching a VM goes
  through here.
- **virt-controller** (2 replicas) — the reconciliation loop. Watches VM objects and
  drives them toward desired state: creates pods to host VMs, triggers migrations,
  manages lifecycle.
- **virt-handler** (DaemonSet, 1 per node = 6 pods) — the node agent. Sets up cgroups
  and namespaces, talks to virtqemud, wires up networking and storage for each VM. Has
  to be local to the node because it interacts with node-level resources. The per-pod
  weight is low; it mostly sits quiet waiting for a VM to appear.

The real overhead is not the DaemonSet — it's the **19 CRDs** KubeVirt installs, and
the six replicated controller pods each opening watches on most of them. KubeVirt ships
support for the full virtualization feature set enabled by default:

```
kubevirts
virtualmachines / virtualmachineinstances / virtualmachineinstancemigrations
virtualmachineinstancereplicasets / virtualmachineinstancepresets
virtualmachinepools
virtualmachineclones
virtualmachineexports
virtualmachinebackups / virtualmachinebackuptrackers
virtualmachinesnapshots / virtualmachinesnapshotcontents / virtualmachinerestores
virtualmachineclusterinstancetypes / virtualmachineinstancetypes
virtualmachineclusterpreferences / virtualmachinepreferences
migrationpolicies
```

All 19 types are watched by all controllers at all times, even with zero VMs running.
KubeVirt-specific watches on ipc5 alone totalled ~60, with `virtualmachineinstances`
holding 11 watchers and `kubevirts` holding 8.

## Object counts: what actually scales with objects vs what doesn't

The intuition that "empty CRDs don't cost anything" is only partially right.

**What does NOT scale with object count:**
- Goroutines — each watch connection is one goroutine regardless of how many objects
  exist in that resource type. A controller watching an empty CRD uses the same goroutine
  as one watching a CRD with 10,000 objects. The controller opens the watch to be
  notified the moment something is *created* — that's the whole point.
- TCP connections — same logic: one connection per watch stream.

**What does scale with object count:**
- Watch cache memory — the API server maintains an in-memory ring buffer of recent
  events per resource type, sized by object count. An empty CRD's cache is essentially
  zero.
- CPU for event dispatch — zero events dispatched if nothing is changing.
- etcd storage — only stores actual objects.

### The current picture (86 registered resource types)

52 types have actual objects; 34 are zero. The goroutine cost is identical for both
groups. The 34 empty ones are all overhead with no current benefit — they exist only
because the operator that installed them might someday need them.

The non-zero counts that matter most:

| Resource | Count | Notes |
|----------|-------|-------|
| events | 166 | Kubernetes event objects; normal churn |
| clusterroles | 113 | RBAC; grows with every operator install |
| clusterrolebindings | 91 | same |
| CRDs | 85 | the full registered CRD count itself |
| serviceaccounts | 81 | one or more per namespace per operator |
| **virtualmachineclusterinstancetypes** | **65** | KubeVirt built-in VM size library — installed automatically |
| **virtualmachineclusterpreferences** | **54** | KubeVirt built-in preference profiles — installed automatically |
| pods | 54 | infrastructure pods |
| apiservices | 54 | one per registered API group |

The KubeVirt rows are notable: those 119 objects (65 instance types + 54 preferences)
are a built-in library of VM sizes and configuration profiles that KubeVirt populates
at install time whether you asked for them or not. They sit in the watch cache of every
KubeVirt controller, for zero VMs running. That is real cache weight, not just a
connection on an empty pipe.

### What metrics to actually watch

Given the above, the metrics worth tracking split into two tiers:

**Structural cost** (driven by what's *installed*, not what's *running*):
- `sum by (node) (apiserver_longrunning_requests{verb="WATCH"})` — total watch burden;
  grows when you install a new operator, shrinks when you uninstall one. Alert if it
  climbs outside a restart cycle.
- `count(apiserver_storage_objects)` — registered resource type count; a proxy for
  "how much operator surface area is installed."
- `go_goroutines{job="k3s_server"}` — tracks the above linearly; useful for spotting
  genuine leaks only in context (compare the ratio to watches, not the absolute number).

**Object-driven cost** (driven by what's *running*):
- `apiserver_storage_objects` per resource — which types actually have objects. The ones
  to watch over time are the KubeVirt instance type/preference counts (stable unless
  you add more) and normal churn resources like pods, secrets, configmaps, events.
- `rate(apiserver_watch_events_total[5m])` by resource — which resources are actively
  generating cache churn. On a truly idle cluster this should be near zero for
  everything except nodes (kubelet heartbeats) and leases (leader election).
- `go_memstats_heap_inuse_bytes{job="k3s_server"}` — heap grows with object-driven
  cache population, not just with watch count. Unbounded growth here over days (not
  hours) would be the signal to investigate.

**What to ignore:**
- Absolute goroutine count in isolation — only meaningful relative to watch count.
- Heap at a static high watermark — Go won't GC when there's 28 GB free. Only care
  about the slope over days, not the level at any given moment.

## The honest conclusion

Nothing is wrong. Nothing needs fixing. This is the cost of the platform.

Kubernetes has substantial baseline overhead even before you run any workloads: embedded
etcd, API server, scheduler, controller-manager. Stacking KubeVirt + SPIRE + Flux +
Vault + cert-manager + MetalLB + monitoring + Tailscale + Traefik on top of that
multiplies the watch count and goroutine count proportionally.

The 11,000 goroutines and 650 MB heap are the idle state of this infrastructure, not a
symptom of something broken. The cluster is doing exactly what this many installed
controllers require.

If the overhead is genuinely a concern, the only lever is uninstalling components not
actively in use. KubeVirt is the heaviest single contributor if VMs are not currently
needed.
