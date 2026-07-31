# Experiment 05 — RBAC

Every pod in Kubernetes has an identity, and that identity determines what it is allowed
to do against the Kubernetes API. This experiment makes the ServiceAccount → Role →
RoleBinding chain concrete: a pod can list pods in its own namespace but nothing more —
no secrets, no cross-namespace access, no destructive verbs. The 403 responses show
exactly where the policy boundary sits, and inspecting the mounted JWT shows what that
identity looks like as a credential.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `rbac-demo` namespace |
| `serviceaccount.yaml` | `pod-reader` ServiceAccount — the identity the pod will run as |
| `role.yaml` | `pod-reader-role` — permits `get`, `list`, `watch` on `pods` in `rbac-demo` only |
| `rolebinding.yaml` | Binds `pod-reader-role` to the `pod-reader` ServiceAccount |
| `deployment.yaml` | Single `kubectl` pod that runs as `pod-reader` and sleeps, ready for exec |
| `jwt-and-serviceaccounts.md` | Deep dive on JWT structure, bound tokens, and how kubelets mint them |

## Apply

The namespace must exist first:

```
kubectl apply -f experiments/05-rbac/namespace.yaml && kubectl apply -f experiments/05-rbac/
```

Confirm all objects are created:

```
kubectl get serviceaccount,role,rolebinding,deployment,pod -n rbac-demo
```

## Observe

Read the Role to see exactly what it permits:

```
kubectl describe role pod-reader-role -n rbac-demo
```

Exec into the pod (get the pod name first):

```
kubectl get pods -n rbac-demo
```

```
kubectl exec -n rbac-demo -it <pod-name> -- sh
```

Inside the pod, the service account token is mounted automatically. Test what is allowed:

```sh
kubectl get pods -n rbac-demo
```

This succeeds — the Role permits it. Now test the boundary:

```sh
kubectl get secrets -n rbac-demo
kubectl get pods -n kube-system
kubectl delete pod -n rbac-demo <pod-name>
```

All three return `Error from server (Forbidden)`. The first two are outside the Role's
resource list; the third uses a verb (`delete`) the Role does not grant.

Inspect the token itself from inside the pod:

```sh
cat /var/run/secrets/kubernetes.io/serviceaccount/token | cut -d. -f2 | base64 -d
```

The payload shows `sub: system:serviceaccount:rbac-demo:pod-reader` — this is the string
the API server uses for RBAC lookups. See `jwt-and-serviceaccounts.md` for a full
breakdown of the token structure and bound-token semantics.

## Teardown

```
kubectl delete namespace rbac-demo
```
