# Experiment 13 — Load Balancing

Kubernetes Services provide built-in load balancing across pod replicas, distributing traffic using round-robin by default without any additional infrastructure. This experiment makes that behavior visible: three nginx pods each return their hostname, so repeated requests through a ClusterIP Service show traffic spreading across all replicas. Understanding how kube-proxy implements this distribution — and its stateless, connection-level nature — is foundational before layering on more sophisticated routing.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `lb-demo` namespace |
| `configmap.yaml` | nginx config that returns `$hostname` as the response body |
| `deployment.yaml` | Three-replica nginx Deployment, each pod returning its own pod name |
| `service.yaml` | ClusterIP Service selecting all `lb-demo` pods on port 80 |
| `job-verify.yaml` | One-shot Job that fires 30 requests at the Service and prints each response |

## Apply

```
kubectl apply -f experiments/13-load-balancing/namespace.yaml -f experiments/13-load-balancing/configmap.yaml -f experiments/13-load-balancing/deployment.yaml -f experiments/13-load-balancing/service.yaml
```

Wait for pods to be ready, then run the verification job:

```
kubectl apply -f experiments/13-load-balancing/job-verify.yaml
```

## Observe

1. Watch the job logs to see requests distributed across pods:

```
kubectl logs -n lb-demo -l job-name=lb-verify --follow
```

Each line is a pod hostname. You should see all three pod names appear across the 30 requests, confirming the Service is load-balancing rather than pinning to one pod.

2. Confirm the three endpoints the Service is forwarding to:

```
kubectl get endpoints -n lb-demo lb-demo-svc
```

3. Check pod distribution across nodes:

```
kubectl get pods -n lb-demo -o wide
```

The scheduler spreads replicas across nodes by default — the responses come from pods on different physical machines.

## Teardown

```
kubectl delete namespace lb-demo
```
