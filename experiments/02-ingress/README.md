# Experiment 02 — Ingress

Kubernetes Services expose pods at the cluster level, but getting traffic in from outside still requires either a NodePort (which leaks implementation detail — node IPs and high ports) or a proper ingress controller. This experiment wires the `hello` deployment from experiment 01 through Traefik, the ingress controller already running in k3s, using hostname-based routing. The goal is to see how a single L7 proxy on a stable address can front multiple services on port 80 using only the HTTP Host header to decide where traffic goes.

## Files

| File | Purpose |
|------|---------|
| `ingress.yaml` | Ingress resource routing `hello.ipc` → the `hello` Service in the `demo` namespace via Traefik |
| `load-balancing-techniques.md` | Reference doc comparing eBPF, IPVS, iptables, and userspace proxies — explains why Traefik is slower than kube-proxy but more capable |

## Prerequisites

Experiment 01 must be applied first. The `demo` namespace, `hello` Deployment, and `hello` Service must exist.

## Apply

```
kubectl apply -f experiments/02-ingress/ingress.yaml
```

## Observe

1. Confirm Traefik picked up the Ingress rule:

   ```
   kubectl get ingress -n demo
   ```

2. Get the Traefik LoadBalancer IP (should be `192.168.88.240`):

   ```
   kubectl get svc -n kube-system traefik
   ```

3. Add a DNS entry so `hello.ipc` resolves to Traefik. Add this line to `/etc/hosts` on omen:

   ```
   192.168.88.240  hello.ipc
   ```

4. Send a request through the ingress controller:

   ```
   curl http://hello.ipc
   ```

   Hit it several times — the pod hostname in the response will rotate across the three pods, now load-balanced by Traefik rather than kube-proxy. The request flow is: `curl → Traefik (:80) → hello Service → pod`.

5. Compare with the NodePort from experiment 01 — both reach the same pods, but through fundamentally different paths. See `load-balancing-techniques.md` for the tradeoff analysis.

## Teardown

```
kubectl delete -f experiments/02-ingress/ingress.yaml
```

The `demo` namespace and `hello` Deployment/Service from experiment 01 remain intact.
