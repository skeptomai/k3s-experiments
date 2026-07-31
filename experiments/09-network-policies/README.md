# Experiment 09 — Network Policies

Kubernetes NetworkPolicy lets you control which pods can talk to which other pods, on which ports. Without any policy, all pods in a namespace can reach each other freely — NetworkPolicy changes the default from "allow all" to a whitelist model where you enumerate permitted traffic and everything else is denied. This matters in multi-tenant clusters or anywhere you want to enforce service boundaries at the network layer.

> **CNI note:** NetworkPolicy enforcement requires a CNI plugin that implements it. This cluster runs Flannel with `wireguard-native` backend, which does not enforce NetworkPolicy — policies are accepted by the API server but have no effect on traffic. The manifests here are correct and will enforce as-is on Cilium or Calico. This experiment documents the correct patterns for when the cluster gains an enforcing CNI.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `netpol-demo` namespace |
| `deployment-backend.yaml` | nginx Deployment + Service (`app: backend`) acting as the protected service |
| `deployment-frontend.yaml` | busybox Deployment (`app: frontend`) representing an authorized client |
| `deployment-client.yaml` | busybox Deployment (`app: client`) representing an unauthorized client |
| `netpol-default-deny.yaml` | Default-deny policy: selects `app: backend` pods and blocks all ingress |
| `netpol-allow-frontend.yaml` | Allow policy: permits ingress to `app: backend` on port 80 from `app: frontend` only |

## Apply

Apply the namespace and workloads first:

```
kubectl apply -f experiments/09-network-policies/namespace.yaml -f experiments/09-network-policies/deployment-backend.yaml -f experiments/09-network-policies/deployment-frontend.yaml -f experiments/09-network-policies/deployment-client.yaml
```

Wait for pods to be Running:

```
kubectl get pods -n netpol-demo
```

## Observe

**Step 1 — Baseline (no policy): all pods reach the backend.**

From the frontend pod:

```
kubectl exec -n netpol-demo deploy/frontend -- wget -qO- --timeout=3 http://backend
```

From the client pod:

```
kubectl exec -n netpol-demo deploy/client -- wget -qO- --timeout=3 http://backend
```

Both return nginx's welcome page. No restrictions.

**Step 2 — Apply default-deny to backend.**

```
kubectl apply -f experiments/09-network-policies/netpol-default-deny.yaml
```

Repeat both `wget` commands above. On an enforcing CNI, both time out — the NetworkPolicy selects `app: backend` pods and specifies `policyTypes: [Ingress]` with no ingress rules, which means deny all inbound.

**Step 3 — Allow only frontend.**

```
kubectl apply -f experiments/09-network-policies/netpol-allow-frontend.yaml
```

The frontend pod can now reach the backend; the client pod is still blocked. Multiple NetworkPolicies targeting the same pod are unioned — any policy that permits the traffic wins, so the allow rule opens exactly one path while the default-deny covers everything else.

**Key concept:** A pod with no NetworkPolicy is fully open. Once any NetworkPolicy selects a pod, that pod is closed except for what the policies explicitly permit. The policies are a whitelist, not a blacklist.

## Teardown

```
kubectl delete namespace netpol-demo
```
