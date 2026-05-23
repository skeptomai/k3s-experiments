# Experiment 01: Namespaces and Deployments

## What you'll observe

- How namespaces isolate resources from the default namespace
- How a Deployment manages a ReplicaSet, which manages Pods
- How Kubernetes reschedules pods when one is killed (self-healing)
- How load is spread across multiple replicas

## Apply

```
kubectl apply -f experiments/01-namespaces-and-deployments/
```

This applies all three manifests: namespace, deployment, service.

## Watch it come up

```
kubectl get pods -n demo -w
```

You'll see three pods transition through `Pending → ContainerCreating → Running`. Each pod lands on whichever node has capacity — check which node each is on:

```
kubectl get pods -n demo -o wide
```

## Hit the service

The service is exposed as a NodePort on 30080. Any node IP works:

```
curl http://192.168.88.53:30080
curl http://192.168.88.52:30080
curl http://192.168.88.54:30080
```

Each response shows the hostname of the pod that handled the request. Hit it several times — you'll see the hostname rotate across your three pods.

## Self-healing demo

Kill a pod by name (use a real pod name from `kubectl get pods -n demo`):

```
kubectl delete pod -n demo <pod-name>
```

Then immediately watch:

```
kubectl get pods -n demo -w
```

The deleted pod disappears and a new one appears within seconds. The Deployment maintains `replicas: 3` — this is the ReplicaSet controller doing its job.

## Scale up/down

```
kubectl scale deployment hello -n demo --replicas=5
kubectl get pods -n demo -o wide
```

Five pods, spread across your three nodes. Scale back down:

```
kubectl scale deployment hello -n demo --replicas=1
```

Kubernetes picks which pods to terminate.

## Inspect the ownership chain

```
kubectl get replicasets -n demo
kubectl describe replicaset -n demo <rs-name>
```

The ReplicaSet is owned by the Deployment. The Pods are owned by the ReplicaSet. This ownership chain is how rollouts and rollbacks work — the Deployment creates a new ReplicaSet and scales the old one down.

## Teardown

```
kubectl delete namespace demo
```

Deleting the namespace cascades — it removes the deployment, replicaset, pods, and service in one shot.
