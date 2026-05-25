# Experiment 05: RBAC

## What you'll observe

- How a ServiceAccount gives a pod an identity within the cluster
- How a Role defines what that identity is allowed to do (and nothing more)
- How a RoleBinding connects the two
- That every pod has a service account token automatically mounted — pods can call the Kubernetes API
- The exact 403 response when a pod tries to do something outside its Role
- That a Role is namespaced — permissions granted in `rbac-demo` do not extend to `kube-system`

## Concepts

| Object | What it is |
|--------|-----------|
| ServiceAccount | An identity for a pod to use when talking to the Kubernetes API |
| Role | A set of permitted verbs on resources, scoped to one namespace |
| ClusterRole | Same as Role but cluster-wide (not used here) |
| RoleBinding | Grants a Role to a ServiceAccount (or user) in a namespace |
| ClusterRoleBinding | Grants a ClusterRole cluster-wide |

The service account token is automatically mounted inside every pod at:
```
/var/run/secrets/kubernetes.io/serviceaccount/token
/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
/var/run/secrets/kubernetes.io/serviceaccount/namespace
```

This token is a JWT. The Kubernetes API server validates it and enforces the RBAC policy
attached to the service account.

## Apply

```
kubectl apply -f experiments/05-rbac/namespace.yaml && kubectl apply -f experiments/05-rbac/
```

## Inspect what was created

```
kubectl get serviceaccount,role,rolebinding -n rbac-demo
```

Read the Role to see exactly what it permits:

```
kubectl describe role pod-reader-role -n rbac-demo
```

You'll see: verbs `get`, `list`, `watch` on resource `pods`, in apiGroup `""` (core API).
Nothing else.

## Exec into the pod

Get the pod name:

```
kubectl get pods -n rbac-demo
```

Exec in:

```
kubectl exec -n rbac-demo -it <pod-name> -- sh
```

## Test what the pod CAN do

Inside the pod, kubectl automatically uses the mounted service account token:

```sh
# List pods in the rbac-demo namespace — ALLOWED
kubectl get pods -n rbac-demo
```

You'll see the pod itself listed. The Role permits this.

## Test what the pod CANNOT do

```sh
# List secrets in rbac-demo — DENIED (secrets not in the Role)
kubectl get secrets -n rbac-demo
```

```sh
# List pods in kube-system — DENIED (Role is scoped to rbac-demo only)
kubectl get pods -n kube-system
```

```sh
# Delete a pod — DENIED (delete verb not in the Role)
kubectl delete pod -n rbac-demo <pod-name>
```

All three return:
```
Error from server (Forbidden): ...
```

This is a 403 from the Kubernetes API server. The pod's identity (the `pod-reader`
service account) has no binding that permits these actions.

## Inspect the token directly

Still inside the pod:

```sh
cat /var/run/secrets/kubernetes.io/serviceaccount/token
```

This is a JWT. You can decode the payload (base64, middle segment) to see the
service account identity embedded in it:

```sh
cat /var/run/secrets/kubernetes.io/serviceaccount/token | cut -d. -f2 | base64 -d 2>/dev/null
```

You'll see fields like `"sub": "system:serviceaccount:rbac-demo:pod-reader"` — that
is the identity string the API server uses to look up RBAC bindings.

Exit the pod:

```sh
exit
```

## What the default service account looks like

Every namespace gets a `default` service account automatically. By default it has
no Role bindings — it can authenticate to the API but is denied everything.

You can verify:

```
kubectl auth can-i list pods --as=system:serviceaccount:rbac-demo:default -n rbac-demo
```

Returns `no`. Compared to the pod-reader account:

```
kubectl auth can-i list pods --as=system:serviceaccount:rbac-demo:pod-reader -n rbac-demo
```

Returns `yes`.

`kubectl auth can-i` is useful for auditing permissions without needing to exec into a pod.

## Teardown

```
kubectl delete namespace rbac-demo
```
