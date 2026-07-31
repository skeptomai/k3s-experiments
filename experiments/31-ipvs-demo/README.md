# Experiment 31 — IPVS Least-Connection Load Balancing

Kubernetes `kube-proxy` supports an IPVS mode that exposes much richer scheduling
algorithms than the default iptables round-robin, including `lc` (least-connection), which
steers new connections to whichever backend currently has the fewest active connections.
This experiment makes that behavior directly observable: a custom Go server tracks its own
active connection count, a `/slow` endpoint holds connections open to create artificial
load, and `/proc/net/ip_vs` on the MetalLB speaker node shows the real IPVS state as
requests are routed away from loaded pods.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `ipvs-demo` namespace |
| `deployment.yaml` | 3-replica Deployment of the demo server; injects `POD_NAME` via downward API |
| `service.yaml` | ClusterIP service (`ipvs-demo`) for Traefik ingress, plus `ipvs-demo-lb` LoadBalancer service for direct IPVS observation |
| `ingress.yaml` | Traefik Ingress for `ipvs-demo.home.skeptomai.com` with TLS |
| `certificate.yaml` | cert-manager Certificate issued by `vault-pki-issuer` for the Ingress hostname |
| `server/main.go` | Go HTTP server: `/` returns pod name + active count, `/slow?s=N` holds connections for N seconds, `/health` for readiness |
| `server/Remfile` | Pelagos build file: Go builder stage → Alpine runtime |
| `build.sh` | Builds the image on ipc7 with `pelagos build` and pushes to local registry (`192.168.89.2:5004`) |
| `demo.sh` | Interactive demo: opens slow connections in background, then runs fast requests to show IPVS routing decisions in real time |

## Build

Build and push the image before applying manifests:

```
bash experiments/31-ipvs-demo/build.sh
```

## Apply

```
kubectl apply -f experiments/31-ipvs-demo/namespace.yaml
kubectl apply -f experiments/31-ipvs-demo/
```

## Observe

Wait for pods to be ready:

```
kubectl get pods -n ipvs-demo -o wide -w
```

Get the LoadBalancer IP assigned by MetalLB:

```
kubectl get svc ipvs-demo-lb -n ipvs-demo
```

**Fast request** — shows which pod handled it and its current active connection count:

```
curl http://<lb-ip>/
```

**Run the interactive demo** — opens slow connections to load specific pods, then shows
fast requests being steered to the lightly-loaded pod:

```
bash experiments/31-ipvs-demo/demo.sh
```

**Inspect IPVS state directly** on the MetalLB speaker node — find which node holds the
VIP, then read `/proc/net/ip_vs`. The `active` column shows live connection counts per
backend; you can watch IPVS route new connections away from loaded pods:

```
ssh -J cb@ipc4.taildd208.ts.net cb@ipc7 "cat /proc/net/ip_vs"
```

(The actual speaker node will be whichever node advertised the VIP via ARP — the demo
script detects this automatically.)

## Teardown

```
kubectl delete namespace ipvs-demo
```
