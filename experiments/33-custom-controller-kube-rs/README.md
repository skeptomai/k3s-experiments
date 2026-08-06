# Experiment 33 — Custom Controller in Rust (kube-rs)

We consume other people's CRDs/controllers everywhere in this cluster
(cert-manager, KubeVirt, Flux, MetalLB, Cilium, the Tailscale operator) but
never *authored* one. This experiment does that: a minimal, concept-complete
custom controller written in Rust with [kube-rs](https://kube.rs), covering
CRD schema generation, `kube::runtime::Controller`, owned resources,
level-triggered/idempotent reconciliation, status subresources, and
finalizers.

Full design rationale and the discussion that shaped every choice below is in
[**issue #15**](https://github.com/skeptomai/k3s-experiments/issues/15) — read
it first.

## What it demonstrates

- **`Echo` CRD** (`edu.k3s-experiments.dev/v1alpha1`, namespaced) with
  `spec.message: string` and `spec.replicas: int`. The CRD's OpenAPI schema
  is **generated from the Rust type**, not hand-written — `#[derive(CustomResource)]`
  (from `kube`) + `schemars` build it at compile time, and the binary can
  print it: `echo-controller --print-crd`. `manifests/crd.yaml` is that
  generated output, checked in for convenience; regenerate it after changing
  `EchoSpec`/`EchoStatus` in `src/main.rs` rather than hand-editing it.
- **Owned resources.** For each `Echo`, the controller creates
  `spec.replicas` ConfigMaps (each holding `spec.message` under key
  `message`), each with an `ownerReference` back to the `Echo`. The
  `Controller` is built with `.owns(configmaps, ...)`, so ConfigMap events
  also trigger the owning `Echo`'s reconcile — not just events on the `Echo`
  itself.
- **Level-triggered, idempotent reconciliation.** The reconcile function
  never trusts an in-memory diff or "what changed" from the triggering
  event. Every pass lists the ConfigMaps actually present (by label
  selector `edu.k3s-experiments.dev/echo=<name>`), reconciles that against
  `spec.replicas` (creating/deleting as needed), then **recounts** what's
  actually there afterward and writes that fresh count to
  `status.readyReplicas` — never the originally-desired number. This makes
  reconcile safe to call redundantly, out of order, or after missed watch
  events; it always converges from real observed state.
- **Finalizer** (`edu.k3s-experiments.dev/cleanup`). Added on creation via
  `kube::runtime::finalizer`. On delete, the controller explicitly deletes
  the owned ConfigMaps and confirms none remain *before* the finalizer is
  removed and deletion is allowed to complete. Kubernetes' own
  owner-reference garbage collection would clean these ConfigMaps up
  anyway — the finalizer is included purely as a teaching device for the
  add/block-deletion/cleanup/remove lifecycle, which is how real finalizers
  (that clean up things Kubernetes GC *can't* reach, like external systems)
  work.

## Layout

| Path | Purpose |
|------|---------|
| `Cargo.toml`, `src/main.rs` | The controller — CRD type, reconcile/cleanup logic, `--print-crd` |
| `Remfile` | Multi-stage build (rust:1-bookworm → debian:bookworm-slim) for `pelagos build` |
| `build-job.yaml` | In-cluster build Job (git-clones this branch, `pelagos build` + `pelagos image push`) |
| `manifests/namespace.yaml` | `custom-controller-demo` namespace |
| `manifests/crd.yaml` | Generated `Echo` CustomResourceDefinition (cluster-scoped — the one unavoidable cluster-wide object here) |
| `manifests/rbac.yaml` | ServiceAccount + namespaced Role + RoleBinding (scoped to `echos`/`echos/status`/`echos/finalizers` and `configmaps`, nothing cluster-wide) |
| `manifests/deployment.yaml` | Controller Deployment (1 replica) |
| `manifests/sample-echo.yaml` | Sample `Echo` (`message: "hello from kube-rs"`, `replicas: 3`) |
| `setup.sh` | Applies namespace/CRD/RBAC/Deployment, waits for rollout (idempotent) |
| `teardown.sh` | Deletes any `Echo` objects first (so finalizer cleanup runs), then everything else (idempotent) |

## Build

This cluster builds images in-cluster via `pelagos build` (Remfile,
Dockerfile-syntax compatible) — no Docker involved. Because the build Job
clones from GitHub over HTTPS, the source has to be on a **pushed branch**,
not just local: this experiment's code lives on `experiment-33-custom-controller`.

Build (single command, run from omen):

```
kubectl apply -f experiments/33-custom-controller-kube-rs/build-job.yaml
```

Watch it:

```
kubectl logs -f job/echo-controller-build
```

On success this pushes `192.168.89.2:5004/echo-controller:latest` to the
local Zot registry on nazgul, which `manifests/deployment.yaml` pulls from.

## Deploy

```
bash experiments/33-custom-controller-kube-rs/setup.sh
```

This applies the namespace, CRD, RBAC, and Deployment, and waits for the
controller pod to become Ready.

## Test

Apply the sample `Echo`:

```
kubectl apply -f experiments/33-custom-controller-kube-rs/manifests/sample-echo.yaml
```

Observe:

```
kubectl -n custom-controller-demo get echo hello -o wide
kubectl -n custom-controller-demo get configmap -l edu.k3s-experiments.dev/echo=hello
kubectl -n custom-controller-demo get echo hello -o jsonpath='{.status.readyReplicas}'
```

You should see 3 ConfigMaps (`hello-0`, `hello-1`, `hello-2`), each
containing `message: hello from kube-rs` and an `ownerReference` pointing
back to the `hello` Echo, and `status.readyReplicas` reading `3`.

**Scale it** — change `spec.replicas` and confirm convergence:

```
kubectl -n custom-controller-demo patch echo hello --type=merge -p '{"spec":{"replicas":5}}'
```

Two more ConfigMaps appear and `status.readyReplicas` becomes `5` — this is
the level-triggered reconcile in action, not an edge-triggered "create 2
more" special case.

**Delete it** — watch the finalizer lifecycle:

```
kubectl -n custom-controller-demo delete echo hello
```

Follow the controller logs during the delete (`kubectl -n
custom-controller-demo logs -f deploy/echo-controller`) to see the "deleting
owned ConfigMap" / "cleanup confirmed" messages, then confirm the
ConfigMaps and the `Echo` itself are both gone and the delete didn't hang on
the finalizer.

## Teardown

```
bash experiments/33-custom-controller-kube-rs/teardown.sh
```

Deletes any remaining `Echo` objects first (triggering finalizer cleanup),
then the Deployment, RBAC, CRD, and namespace. Safe to re-run.

## Safety

Fully self-contained: new namespace (`custom-controller-demo`), new CRD
group (`edu.k3s-experiments.dev`), namespace-scoped RBAC. The only
cluster-scoped object is the CRD itself (CustomResourceDefinition is
inherently cluster-scoped) — nothing here touches OpenBao, SPIRE, KubeVirt,
MetalLB, or any existing namespace.
