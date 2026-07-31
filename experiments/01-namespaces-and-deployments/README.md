# Experiment 01 — Namespaces and Deployments

The foundational Kubernetes primitives. A Namespace isolates resources; a Deployment
declares desired state (3 replicas of nginx); Kubernetes maintains that state
continuously — rescheduling pods that die, spreading them across nodes. This experiment
makes that ownership chain and self-healing behavior tangible.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `demo` namespace that scopes all other resources |
| `deployment.yaml` | 3-replica nginx Deployment; Kubernetes creates a ReplicaSet which creates the Pods |
| `service.yaml` | NodePort Service on port 30080 — exposes the pods on every node's IP |

## Apply

The namespace must exist before the other resources. Apply it first, then the rest:

```
kubectl apply -f experiments/01-namespaces-and-deployments/namespace.yaml
kubectl apply -f experiments/01-namespaces-and-deployments/
```

## Observe

Watch pods come up — you'll see them move through `Pending → ContainerCreating → Running`:

```
kubectl get pods -n demo -w
```

Check which node each pod landed on:

```
kubectl get pods -n demo -o wide
```

Hit the service — any node IP works. Get one with:

```
kubectl get nodes -o wide
```

Then:

```
curl http://<node-ip>:30080
```

Each response includes the hostname of the pod that handled it. Hit it several times and
you'll see the hostname rotate across all three pods.

## Self-healing

Delete a pod by name (use a real name from `kubectl get pods -n demo`):

```
kubectl delete pod -n demo <pod-name>
```

Watch immediately — a replacement appears within seconds. The ReplicaSet controller sees
`actual=2, desired=3` and creates a new pod.

## Ownership chain

```
kubectl get replicasets -n demo
kubectl describe replicaset -n demo <rs-name>
```

Deployment → ReplicaSet → Pods. This chain is how rolling updates work: a new Deployment
revision creates a new ReplicaSet, scales it up, and scales the old one down.

## Teardown

```
kubectl delete namespace demo
```

Deleting the namespace cascades — Deployment, ReplicaSet, Pods, and Service all go with it.
