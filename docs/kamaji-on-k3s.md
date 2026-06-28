# Kamaji Hosted Control Planes on k3s

Why an earlier Kamaji experiment found k3s "not adequate," what the real gap was,
and whether this cluster should switch distributions. Short version: the friction
was k3s's lightweight default add-ons vs. Kamaji's stated requirements — **not** a
fundamental k3s incompatibility — and switching distros would help Kamaji only
marginally while hurting the pelagos-as-CRI dogfooding that this cluster exists for.

## Background: what Kamaji is

[Kamaji](https://github.com/clastix/kamaji) is a Hosted Control Plane manager. It
runs each tenant cluster's control plane (`kube-apiserver`, controller-manager,
scheduler) as **Pods on a management cluster**, instead of on dedicated machines.
Tenant worker nodes then join that hosted, vanilla-Kubernetes control plane. The
control-plane datastore is either a multi-tenant **etcd** or a kine-backed
**PostgreSQL/MySQL/NATS**.

## The framing correction

Kamaji **officially supports k3s as a management cluster** — the docs list "any
CNCF-certified Kubernetes cluster ... including RKE2 and K3s." So the problem we
hit was never "k3s can't run Kamaji." It was k3s's *lightweight defaults* failing
to satisfy Kamaji's explicit management-cluster requirements:

| Requirement | Kamaji wants | k3s default ships | Gap |
|---|---|---|---|
| CNI | Calico / Cilium | flannel | Usually OK; verify policy/feature needs |
| CSI + StorageClass | Reschedulable PV for tenant datastores | local-path-provisioner | **PVC pins to first node** |
| LoadBalancer | Pool of routable IPs (MetalLB / cloud LB) | Klipper / ServiceLB | **Shared host ports, not per-tenant IPs** |

## Why k3s came up short — concrete reasons

1. **Service exposure (the big one).** Every hosted tenant control plane needs its
   own routable API endpoint reachable by *that* tenant's worker nodes. k3s's
   ServiceLB (Klipper) is a shared-host-port mechanism, not a pool of real IPs, so
   it can't cleanly hand out a distinct LB IP per tenant control plane. Kamaji's
   docs effectively assume MetalLB; you must disable `servicelb` and install it.

2. **Storage for tenant etcd.** Multi-tenant etcd (or kine-backed Postgres/MySQL)
   needs persistent volumes that can reschedule. k3s's local-path provisioner
   **pins the PVC to the node that first bound it** — the same sticky-PVC behavior
   already documented on this cluster. For etcd that's an availability problem, not
   a nuisance.

3. **Management-cluster SPOF.** If the k3s management cluster is single-server
   SQLite (kine), it is a single point of failure for *every* hosted control plane
   — which defeats the purpose of hosted control planes.

4. **The "k3s can't schedule pods" red herring.** A
   [Kamaji discussion](https://github.com/clastix/kamaji/discussions/1006)
   describes using k3s as an API/CRD layer *only*, with pods deployed on a separate
   cluster. Maintainers call that unsupported and point to **vCluster / k3k**
   instead. That is a different scenario from running Kamaji normally on a k3s
   management cluster, but it's the kind of thread that makes k3s look incompatible
   when it isn't.

## Should this cluster switch distributions?

**Recommendation: no — fix the add-ons, keep the distro.**

- **This is the pelagos dogfooding cluster.** All six nodes run `pelagos://` as the
  CRI — the runtime we are building. k3s's clean external-CRI path
  (`--container-runtime-endpoint`) is *why* pelagos slots in so easily.
- **The Kamaji gap is infra, not distro.** k3s becomes a conformant Kamaji
  management cluster by swapping three pieces: install **MetalLB** (disable
  servicelb), add a **reschedulable CSI / StorageClass** for tenant datastores, and
  confirm the **CNI** meets feature needs. That's configuration, not migration.
- **Don't conflate the experiment with the test bed.** Cleaner to keep this cluster
  as the pelagos test bed and stand up Kamaji **separately**, so a tenant
  control-plane experiment can't destabilize runtime work.

### Distro trade-offs if we ever did switch

| Distro | Kamaji fit | pelagos-as-CRI fit | HA datastore | Notes |
|---|---|---|---|---|
| **k3s** (current) | Good once MetalLB + CSI added | **Best** — clean external CRI | Embedded etcd via `--cluster-init` | Lightweight defaults need replacing |
| **RKE2** | Good (Kamaji-blessed, upstream components) | **Worse** — opinionated bundled containerd | Embedded etcd by default | Natural "step up" in Rancher family |
| **kubeadm** | Good (vanilla) | Good — clean custom CRI | You run etcd yourself | Most operational overhead |

RKE2/kubeadm would help Kamaji only marginally while RKE2 specifically *hurts*
pelagos dogfooding — the higher-priority workload here.

## Cluster state (audited 2026-06-28)

Live findings from the running cluster, mapped to the three Kamaji requirements.

### Nodes & taints

| Node | Class | k3s role | Taints |
|------|-------|----------|--------|
| ipc1 | standard (G5400T, 2c/4t, 32G) | **control-plane only** | `slow:NoSchedule`, `node-role.../control-plane:NoSchedule` |
| ipc2 | standard (G5400T, 2c/4t, 32G) | worker | `slow:NoSchedule` |
| ipc3 | standard (G5400T, 2c/4t, 32G) | worker | `slow:NoSchedule` |
| ipc4 | performance (i5-12500T) | worker | none |
| ipc5 | performance (i5-12500T) | worker | none |
| ipc6 | performance (i5-12500T, 16G) | worker | none |

### Requirement gaps

| Requirement | Found | Verdict |
|---|---|---|
| **LoadBalancer** | No MetalLB. ServiceLB/Klipper active (`svclb-traefik` on ipc4/5/6, IPs .55/.56/.57) | ❌ **Mandatory gap** — must add MetalLB, disable servicelb |
| **Storage** | `nfs` (default, nazgul, Immediate, reschedulable) + node-pinned `local-path` + manual `vault-local` | ⚠️ Reschedulable SC exists, but **etcd-on-NFS is performance-discouraged** |
| **CNI** | flannel `wireguard-native` (encrypted; no NetworkPolicy) | ⚠️ Works for Kamaji; no policy isolation |

k3s server config (ipc1): `flannel-backend: wireguard-native`, `disable: local-storage`.

## ipc2 / ipc3 are currently dead weight

A sharp observation worth recording: ipc2 and ipc3 carry `slow:NoSchedule` **and**
hold no control-plane role. `NoSchedule` means nothing lands there unless it
explicitly *tolerates* `slow` — and almost nothing does (ServiceLB, CoreDNS,
Traefik all run on the untainted performance nodes). flannel is embedded in the
k3s agent, not a pod. So ipc2/ipc3 run essentially **nothing**: they are powered-on
but idle.

That makes them the obvious candidates for a job that *suits* "always-on but slow":
**a control-plane / etcd quorum.** Promoting ipc1-3 to an HA control plane gives the
weak nodes a fitting role (etcd is light on CPU/RAM) while all real workloads stay
on the performance nodes ipc4/5/6. See below.

## Making ipc1-3 an HA control plane

Goal: control-plane components **only** on ipc1-3 (embedded etcd, 3-node quorum,
tolerates 1 failure); workloads stay on ipc4/5/6.

**Why it fits this cluster:**
- Answers the "why do ipc2/3 exist" problem — gives the idle slow nodes a real job.
- etcd is light on CPU/RAM (fine for G5400T / 32G) — its one sensitivity is **disk
  fsync latency**. **Audited 2026-06-28:** all three boot from a 238 GB **SATA SSD**
  (`rotational=0`, model `DEM28-B56M41BW1D`, an Innodisk SATADOM-class module) — not
  eMMC/SD. SATA SSD fsync latency is well within etcd's tolerance, so **storage is a
  go.** (SATADOM modules have modest sustained write IOPS vs. consumer SSDs, but
  etcd's small WAL fsyncs are a fine fit.)
- Keeps every general workload on the performance nodes via the existing `slow`
  taint.

**Migration shape (k3s SQLite → embedded etcd):** backup → `--cluster-init` on ipc1
→ reprovision ipc2/ipc3 as servers → verify 3-member quorum. The full step-by-step
(with rollback) lives in **`ipc1-3-control-plane-ha-runbook.md`**.

**Caveats:**
- Quorum of 3 tolerates exactly **one** node down; lose two and the API goes
  read-only. Acceptable for a homelab.
- etcd really wants local SSD — if these nodes have slow storage, expect
  `apply request took too long` warnings under load.

## To make this cluster Kamaji-ready (checklist)

- [x] **Install MetalLB** ✅ done 2026-06-28 — pool `192.168.88.240-.250`, L2/ARP (see `metallb.md`)
- [x] **Disable k3s ServiceLB** ✅ done — `disable: servicelb` on the servers; Traefik migrated to MetalLB `.240`
- [ ] **Storage for tenant etcd** — `nfs` SC is reschedulable but etcd-on-NFS is discouraged; consider a local-SSD-backed CSI or accept the NFS perf caveat
- [ ] **CNI** — flannel works; add Calico/Cilium only if tenant NetworkPolicy is needed
- [x] **HA control plane** on ipc1-3 via `--cluster-init` ✅ done 2026-06-28 (see `ipc1-3-control-plane-ha-runbook.md`) — removes the management-cluster SPOF
- [x] **HA management-cluster API endpoint** ✅ kube-vip VIP `192.168.88.58` (see `kube-vip.md`) — also the model for giving each hosted tenant control plane a stable endpoint, though tenants will use MetalLB-assigned IPs rather than this single CP VIP

## Sources

- [Kamaji on generic infra — management-cluster requirements](https://kamaji.clastix.io/getting-started/kamaji-generic/)
- [Kamaji datastore concepts (etcd / kine multi-tenancy)](https://kamaji.clastix.io/concepts/datastore/)
- [Kamaji alternative datastores (MySQL/PostgreSQL/NATS via kine)](https://kamaji.clastix.io/guides/alternative-datastore/)
- [clastix/kamaji discussion #1006 — k3s API-only scenario unsupported](https://github.com/clastix/kamaji/discussions/1006)
- [clastix/kamaji — project overview](https://github.com/clastix/kamaji)
- [k3s networking / ServiceLB (Klipper) docs](https://docs.k3s.io/networking)
