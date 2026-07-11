# JWTs and ServiceAccounts in Kubernetes

## JWTs

JWT = JSON Web Token. A compact, self-describing credential with three base64-encoded
segments separated by dots:

```
<header>.<payload>.<signature>
```

- **Header** — algorithm used to sign (`RS256`, `ES256`, etc.)
- **Payload** — the claims: who this is, when it expires, what it's for
- **Signature** — cryptographic proof that the issuer created this token and it hasn't been tampered with

The signature is what makes JWTs trustworthy without a database lookup. The API server
holds the public key and verifies the signature locally on every request. If the token
was altered in any way, the signature check fails. No session store, no round-trip — just math.

### The token from this experiment

```json
{
  "sub": "system:serviceaccount:rbac-demo:pod-reader",
  "iss": "https://kubernetes.default.svc.cluster.local",
  "aud": ["https://kubernetes.default.svc.cluster.local", "k3s"],
  "kubernetes.io": {
    "namespace": "rbac-demo",
    "pod": { "name": "rbac-tester-77fc98cd4f-drtbp" },
    "serviceaccount": { "name": "pod-reader" },
    "node": { "name": "ipc7" }
  }
}
```

| Field | Meaning |
|-------|---------|
| `sub` | Subject — the identity string RBAC lookups run against |
| `iss` | Issuer — the k3s API server that minted this token |
| `aud` | Audience — must match what the API server expects; prevents token reuse across services |
| `iat` / `exp` / `nbf` | Issued-at, expiry, not-before — time bounds on the token |
| `jti` | Unique token ID — allows revocation if tracked |
| `kubernetes.io` | Bound token claims: pod UID, node UID, service account name |

### Bound tokens

Kubernetes service account tokens are **bound tokens** (default since k8s 1.21). They are
bound to a specific pod, node, and expiry — the token is only valid while that exact pod
is running on that exact node. Earlier Kubernetes used long-lived static tokens stored as
Secrets; bound tokens are significantly more secure because a leaked token expires and is
tied to a specific workload.

---

## ServiceAccounts

### Where they live

A ServiceAccount object is a record in etcd — a name, namespace, and UID. It carries no
credentials directly. You can inspect one:

```
kubectl get serviceaccount pod-reader -n rbac-demo -o yaml
```

### Three ways to create one

1. **Automatic** — every namespace gets a `default` ServiceAccount when the namespace is created
2. **Explicit** — declared in YAML and applied (`serviceaccount.yaml` in this experiment)
3. **Imperative** — `kubectl create serviceaccount <name> -n <namespace>`

### How a pod gets its token

When a pod is admitted to the cluster, the **TokenRequest admission controller** intercepts
it. It sees `serviceAccountName: pod-reader` in the pod spec and calls the API server's
`TokenRequest` API to mint a fresh bound JWT for that pod. The kubelet then mounts it into
the pod's filesystem:

```
/var/run/secrets/kubernetes.io/serviceaccount/token      ← the JWT
/var/run/secrets/kubernetes.io/serviceaccount/ca.crt     ← cluster CA certificate
/var/run/secrets/kubernetes.io/serviceaccount/namespace  ← the pod's namespace
```

The kubelet also rotates the token automatically before it expires — no pod restart required.

### How RBAC evaluation works on each API call

```
Pod makes API call
  → sends JWT in Authorization: Bearer <token> header
  → API server validates signature with its public key
  → extracts sub: "system:serviceaccount:rbac-demo:pod-reader"
  → looks up RoleBindings/ClusterRoleBindings that reference this subject
  → finds pod-reader-binding → pod-reader-role
  → checks: does pod-reader-role permit [verb] on [resource] in [namespace]?
  → yes → 200 / no → 403
```

This happens on **every single API call**. There is no session. The token is stateless
proof of identity; RBAC policy is evaluated fresh each time. If you delete the RoleBinding,
the next API call from the pod is immediately denied — no restart needed.

### The `default` ServiceAccount

Every pod that doesn't specify `serviceAccountName` gets the `default` SA automatically.
In k3s and vanilla Kubernetes, `default` has no RoleBindings — it can authenticate but is
denied everything.

Some older setups and Helm charts bind `cluster-admin` to `default`, which is a significant
security hole. Auditing what's bound to `default` across all namespaces is a common security
check:

```
kubectl get rolebindings,clusterrolebindings -A -o wide | grep default
```

### Roles vs ClusterRoles

| Kind | Scope | Use when |
|------|-------|----------|
| `Role` | Single namespace | Pod needs access to resources in its own namespace only |
| `ClusterRole` | Entire cluster | Access to cluster-wide resources (nodes, PVs) or same permissions across all namespaces |
| `RoleBinding` | Grants a Role or ClusterRole within one namespace | Limit a ClusterRole to a single namespace |
| `ClusterRoleBinding` | Grants a ClusterRole cluster-wide | Cluster operators, monitoring agents, etc. |

A common pattern: define a `ClusterRole` with the permission set once, then use namespace-scoped
`RoleBindings` to grant it selectively per namespace. Avoids duplicating Role definitions.
