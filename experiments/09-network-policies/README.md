# Experiment 09: Network Policies

## What you'll observe

- Without any NetworkPolicy, all pods in a namespace can reach each other freely
- A default-deny policy blocks all ingress to selected pods — including previously open traffic
- An allow rule opens a specific path: one pod label to another, on one port
- That NetworkPolicy is a whitelist, not a blacklist — you enumerate what's allowed, everything else is denied

## CNI note

NetworkPolicy requires a CNI plugin that enforces it. k3s ships with Flannel, which
does not enforce NetworkPolicy natively. However, k3s includes a built-in network
policy controller (based on kube-router) that implements enforcement via iptables.
NetworkPolicy works on this cluster without any additional setup.

## Concepts

A NetworkPolicy selects a set of pods via `podSelector` and defines ingress and/or
egress rules for them. If a pod is selected by at least one NetworkPolicy, only
traffic explicitly permitted by a matching rule is allowed. If a pod is not selected
by any NetworkPolicy, all traffic is allowed (open by default).

**Default-deny pattern:** A NetworkPolicy with an empty `ingress: []` (or just
`policyTypes: [Ingress]` with no ingress rules) selects pods and denies all inbound
traffic. This is the foundation — apply it first, then layer in allow rules.

```
No NetworkPolicy → pod is open (allow all)
NetworkPolicy with no ingress rules → pod is closed (deny all ingress)
NetworkPolicy with ingress rules → only matching traffic is allowed
```

Multiple NetworkPolicies targeting the same pod are **unioned** — if any policy
permits the traffic, it is allowed.

## Apply (initial state — no policies)

```
kubectl apply -f experiments/09-network-policies/namespace.yaml && kubectl apply -f experiments/09-network-policies/deployment-backend.yaml && kubectl apply -f experiments/09-network-policies/deployment-frontend.yaml && kubectl apply -f experiments/09-network-policies/deployment-client.yaml
```

Wait for all pods to be Running:

```
kubectl get pods -n netpol-demo
```

## Step 1: verify open traffic (no policy)

Get pod names:

```
kubectl get pods -n netpol-demo
```

From the **frontend** pod, reach the backend Service:

```
kubectl exec -n netpol-demo <frontend-pod> -- wget -qO- --timeout=3 http://backend
```

From the **client** pod, do the same:

```
kubectl exec -n netpol-demo <client-pod> -- wget -qO- --timeout=3 http://backend
```

Both return nginx's welcome page. No policies, no restrictions.

## Step 2: apply default-deny to backend

```
kubectl apply -f experiments/09-network-policies/netpol-default-deny.yaml
```

This policy selects `app: backend` and declares `policyTypes: [Ingress]` with no
ingress rules — meaning deny all inbound traffic to the backend pod.

Retry from both pods:

```
kubectl exec -n netpol-demo <frontend-pod> -- wget -qO- --timeout=3 http://backend
kubectl exec -n netpol-demo <client-pod> -- wget -qO- --timeout=3 http://backend
```

Both time out. The backend is now unreachable from anywhere.

## Step 3: allow frontend only

```
kubectl apply -f experiments/09-network-policies/netpol-allow-frontend.yaml
```

This policy also selects `app: backend` and adds an ingress rule: allow TCP port 80
from pods with label `app: frontend`.

Test again:

```
kubectl exec -n netpol-demo <frontend-pod> -- wget -qO- --timeout=3 http://backend
```

Returns nginx welcome page — allowed.

```
kubectl exec -n netpol-demo <client-pod> -- wget -qO- --timeout=3 http://backend
```

Times out — still blocked. `client` has `app: client`, which matches no allow rule.

## Inspect the policies

```
kubectl get networkpolicy -n netpol-demo
kubectl describe networkpolicy backend-allow-frontend -n netpol-demo
```

## Egress policies

This experiment only covers ingress (inbound traffic to a pod). Egress policies
control outbound traffic from a pod and work the same way — `policyTypes: [Egress]`
with `egress` rules. A common pattern is to allow egress only to DNS (port 53) and
specific services, blocking all other outbound traffic.

## Namespace selectors

Rules can also select by namespace rather than pod label:

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: production
```

This allows traffic from any pod in the `production` namespace. You can combine
`namespaceSelector` and `podSelector` in the same rule to allow a specific pod
in a specific namespace.

## Teardown

```
kubectl delete namespace netpol-demo
```
