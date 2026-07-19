# KubeVirt Suspend / Resume

Procedure for temporarily removing KubeVirt from the cluster when no VMs are running,
and restoring it later. Useful for reclaiming the ~12-pod, 19-CRD overhead when VMs
are not needed.

## Prerequisites

- No VMs or VMIs running: `kubectl get vmi -A` must return empty
- Flux is managing KubeVirt via `clusters/ipc/kubevirt.yaml` with `prune: true`

## How KubeVirt installs itself (why cleanup is non-obvious)

The operator manifest (`manifests/kubevirt/kubevirt-operator.yaml`) only contains the
operator deployment, RBAC, and the `kubevirts.kubevirt.io` CRD. When the operator first
reconciles the KubeVirt CR, it dynamically installs the other 18 CRDs (all the
`virtualmachine*.kubevirt.io` types), the virt-api/controller/handler deployments,
webhooks, and ~119 built-in instance type/preference objects. None of that is in the
manifest file.

The clean uninstall path relies on the operator processing its CR's finalizer
(`foregroundDeleteKubeVirt`) to undo all of that dynamic installation. This only works
if virt-operator pods are Running. If they are Pending, the whole cleanup path breaks:
the webhook call blocks CR deletion, the finalizer never gets processed, and the 18
dynamically-installed CRDs are left behind orphaned.

**Before suspending, check operator health:**

```
kubectl get pods -n kubevirt -l kubevirt.io=virt-operator
```

Both pods must be `Running`. If they are `Pending`, investigate and fix that first
(`kubectl describe pod -n kubevirt <pod>` to see the scheduling failure). Proceeding
with a Pending operator means all cleanup must be done manually.

## Suspend (remove from cluster)

**Step 1 — suspend Flux** so it won't re-apply resources during cleanup:

```
flux suspend kustomization kubevirt
```

**Step 2 — delete the KubeVirt CR** and wait for the operator to finish tearing down
virt-api, virt-controller, virt-handler, all 18 dynamic CRDs, and their objects:

```
kubectl delete kubevirt kubevirt -n kubevirt
kubectl get pods -n kubevirt -w
```

Wait until only virt-operator pods remain. The operator removes everything else, then
removes itself last. This can take 60–90s.

**Step 3 — delete the operator manifest resources:**

```
kubectl delete -f manifests/kubevirt/kubevirt-operator.yaml
```

This removes the virt-operator deployment, RBAC, the `kubevirts.kubevirt.io` CRD, and
the `kubevirt` namespace.

**Verify nothing remains — do not skip this:**

```
kubectl get crd | grep kubevirt
kubectl get ns kubevirt
```

Both must return empty / not found. KubeVirt installs resources dynamically at runtime
that are not listed in any manifest file. The only way to confirm they are gone is to
check directly. Do not assume the operator cleaned up everything just because the pods
are gone.

## Fallback: operator was Pending

If the operator pods were Pending and you already ran `flux suspend`, the webhooks and
finalizer must be removed manually before anything else can be deleted:

```
kubectl delete validatingwebhookconfiguration virt-operator-validator virt-api-validator
kubectl delete mutatingwebhookconfiguration virt-api-mutator
kubectl patch kubevirt kubevirt -n kubevirt --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl delete kubevirt kubevirt -n kubevirt
kubectl delete -f manifests/kubevirt/kubevirt-operator.yaml
kubectl get crd -o name | grep -E "\.(kubevirt|backup\.kubevirt|clone\.kubevirt|export\.kubevirt|instancetype\.kubevirt|migrations\.kubevirt|pool\.kubevirt|snapshot\.kubevirt)\.io" | xargs kubectl delete
```

The last line deletes the 18 CRDs that the operator would have removed itself during
normal CR finalizer processing. They are not in the operator manifest and will not be
cleaned up otherwise — you'd need to notice them with `kubectl get crd | grep kubevirt`
after thinking cleanup was complete.

If the namespace gets stuck in Terminating (stale API group discovery from removed
CRDs):

```
kubectl get ns kubevirt -o json | python3 -c "import sys,json; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; print(json.dumps(ns))" | kubectl replace --raw /api/v1/namespaces/kubevirt/finalize -f -
```

## Resume (restore to cluster)

```
flux resume kustomization kubevirt
flux get kustomization kubevirt
kubectl get pods -n kubevirt -w
```

Flux re-applies the operator manifest and KubeVirt CR in one pass. The operator
reinstalls all 18 dynamic CRDs, virt-api, virt-controller, the virt-handler DaemonSet,
and the 119 built-in instance type/preference objects. Operator startup takes ~30s;
full component rollout another ~60s.

## Operator lifecycle pattern — applies beyond KubeVirt

KubeVirt uses a common operator pattern: a CR with a finalizer gates all dynamic
installation and uninstall. The operator manifest ships the minimum needed to get the
operator running (its own deployment, RBAC, and one CRD). Everything else — additional
CRDs, deployments, webhooks, built-in objects — is installed by the operator at runtime
when it reconciles the CR.

This means:
- Static manifests do not reflect the full cluster footprint of an operator.
- Uninstall only works cleanly if the operator is healthy enough to process its CR's
  finalizer. A Pending or CrashLooping operator leaves all dynamically-installed
  resources orphaned when you delete the CR.
- After any operator removal, verify with `kubectl get crd | grep <operator-domain>`
  and `kubectl get all -n <operator-namespace>`. Do not assume pods disappearing means
  everything is gone.

Other operators in this cluster that follow the same pattern and carry the same risk:
cert-manager, Vault (Raft cluster init), and any Flux HelmRelease-managed operator that
installs CRDs via a hook. The gap between "pods gone" and "cluster fully clean" varies
by operator but is never zero.

## What is preserved vs removed

| Item | Suspend removes? | Resume restores? |
|------|-----------------|-----------------|
| virt-operator, virt-api, virt-controller pods | Yes | Yes (Flux) |
| virt-handler DaemonSet (6 pods) | Yes | Yes (Flux) |
| All 19 CRDs (kubevirt.io family) | Yes | Yes (operator) |
| 65 VirtualMachineClusterInstanceTypes | Yes | Yes (operator) |
| 54 VirtualMachineClusterPreferences | Yes | Yes (operator) |
| Git state (`clusters/ipc/kubevirt.yaml`) | No | — |
| Any VM/VMI objects | Yes (none present) | Not restored |
