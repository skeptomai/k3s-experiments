# Kubernetes Acronyms and Interfaces

## The Three C*I Interfaces

Before these interfaces existed, storage/network/runtime drivers were compiled directly into Kubernetes. Vendors had to submit PRs to the Kubernetes repo and wait for a release cycle to ship changes. The C*I interfaces let vendors develop and update their own drivers independently.

| Acronym | Expands to | What it standardizes |
|---------|-----------|----------------------|
| **CSI** | Container Storage Interface | How storage providers plug in (EBS, Ceph, Longhorn, etc.) |
| **CNI** | Container Network Interface | How networking plugins plug in (Flannel, Calico, Cilium, etc.) |
| **CRI** | Container Runtime Interface | How container runtimes plug in (containerd, CRI-O, etc.) |

k3s ships with defaults for all three: Flannel (CNI), containerd (CRI), and local-path (CSI).

### CSI and reclaim policy

The CSI driver is what makes PV reclaim policies meaningful for network-backed storage. When you delete a PVC backed by EBS with `reclaimPolicy: Delete`, the EBS CSI driver calls the AWS API and deletes the actual volume — gone from your account and billing.

This only works for dynamically provisioned volumes. If you manually pre-provisioned a PV, Kubernetes won't delete the underlying resource regardless of reclaim policy — it won't touch something it didn't create.

`Retain` makes practical sense for network-backed storage (keep the EBS volume after the PVC is gone, recover data before cleanup). For local-path, `Retain` just leaves a stale PV object and a directory on a node's disk with no clear ownership — not very useful, since local-path data isn't recoverable if the node dies anyway.

## Other Acronyms Worth Knowing

| Acronym | Expands to | Notes |
|---------|-----------|-------|
| **CRD** | Custom Resource Definition | Lets you extend the Kubernetes API with your own resource types |
| **RBAC** | Role-Based Access Control | Controls who can do what in the cluster |
| **HPA** | Horizontal Pod Autoscaler | Scales replica count based on CPU/memory/custom metrics |
| **VPA** | Vertical Pod Autoscaler | Adjusts CPU/memory requests on running pods |
| **OPA** | Open Policy Agent | Policy engine, often used for admission control |
| **ETCD** | — | Not an acronym — it's a name. The distributed key-value store that holds all Kubernetes state. |
