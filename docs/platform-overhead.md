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
