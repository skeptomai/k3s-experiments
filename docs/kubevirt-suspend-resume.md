# KubeVirt Suspend / Resume

Procedure for temporarily removing KubeVirt from the cluster when no VMs are running,
and restoring it later. Useful for reclaiming the ~12-pod, 19-CRD overhead when VMs
are not needed.

## Prerequisites

- No VMs or VMIs running: `kubectl get vmi -A` must return empty
- Flux is managing KubeVirt via `clusters/ipc/kubevirt.yaml` with `prune: true`

## Suspend (remove from cluster)

```
flux suspend kustomization kubevirt
kubectl delete validatingwebhookconfiguration virt-operator-validator virt-api-validator
kubectl delete mutatingwebhookconfiguration virt-api-mutator
kubectl patch kubevirt kubevirt -n kubevirt --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl delete kubevirt kubevirt -n kubevirt
kubectl delete -f manifests/kubevirt/kubevirt-operator.yaml
kubectl get crd -o name | grep -E "\.(kubevirt|backup\.kubevirt|clone\.kubevirt|export\.kubevirt|instancetype\.kubevirt|migrations\.kubevirt|pool\.kubevirt|snapshot\.kubevirt)\.io" | xargs kubectl delete
```

**Why the manual steps:** The happy path (delete the CR, let the operator clean up)
requires both virt-operator pods to be Running so they can process the CR's finalizer.
In practice virt-operator pods are often Pending (node pressure or scheduling hiccups),
which blocks the CR deletion at the webhook call and leaves the finalizer hanging.

The safe sequence regardless of operator health:
1. Suspend Flux so it won't re-apply anything during cleanup.
2. Remove the three webhook configurations — these call into virt-operator and virt-api
   and will block CR deletion if those pods aren't healthy.
3. Patch the finalizer off the CR so the delete isn't gated on operator liveness.
4. Delete the CR.
5. Delete the operator manifest (removes virt-operator deployment, RBAC, the
   `kubevirts.kubevirt.io` CRD, and the namespace).
6. Delete the 18 additional CRDs that the operator installed dynamically when it
   reconciled the CR — these are not in the operator manifest and must be removed
   explicitly.

If the namespace gets stuck in Terminating (stale API group discovery from the removed
CRDs), clear it with:

```
kubectl get ns kubevirt -o json | python3 -c "import sys,json; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; print(json.dumps(ns))" | kubectl replace --raw /api/v1/namespaces/kubevirt/finalize -f -
```

## Resume (restore to cluster)

Flux holds the full desired state in git. Resuming reconciliation is sufficient —
Flux re-applies the operator deployment and the KubeVirt CR in one pass, and the
operator reinstalls all components (virt-api, virt-controller, virt-handler DaemonSet,
CRDs, built-in instance types, and preferences).

```
flux resume kustomization kubevirt
flux get kustomization kubevirt
kubectl get pods -n kubevirt -w
```

Operator startup takes ~30s; full component rollout another ~60s.

## What is preserved vs removed

| Item | Suspend removes? | Resume restores? |
|------|-----------------|-----------------|
| virt-operator, virt-api, virt-controller pods | Yes | Yes (Flux) |
| virt-handler DaemonSet (6 pods) | Yes | Yes (Flux) |
| All 19 CRDs (kubevirt.io family) | Yes (operator finalizer) | Yes (operator) |
| 65 VirtualMachineClusterInstanceTypes | Yes | Yes (operator) |
| 54 VirtualMachineClusterPreferences | Yes | Yes (operator) |
| `kubevirt` namespace | No | — |
| Git state (`clusters/ipc/kubevirt.yaml`) | No | — |
| Any VM/VMI objects | Yes (none present) | Not restored |
