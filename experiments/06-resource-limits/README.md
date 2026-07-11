# Experiment 06: Resource Limits and Scheduling

## What you'll observe

- The difference between resource **requests** and **limits**
- How the scheduler uses requests to decide which node a pod lands on
- The three QoS classes and how Kubernetes assigns them
- A container that exceeds its memory limit getting OOMKilled
- A pod with impossible requests staying Pending indefinitely
- How to read node resource allocation

## Concepts

### Requests vs Limits

| | Requests | Limits |
|-|---------|--------|
| What it is | The amount the scheduler reserves on a node | The hard cap the container may not exceed |
| CPU behaviour | Scheduler won't place pod on node without this much free | Container is **throttled** (slowed down, not killed) |
| Memory behaviour | Scheduler won't place pod on node without this much free | Container is **OOMKilled** (killed immediately) |
| Required? | No, but strongly recommended | No |

If you set no requests or limits, the scheduler places the pod anywhere and the
container can consume unlimited resources — starving other workloads on the node.

### QoS Classes

Kubernetes assigns a QoS class to every pod based on how you've set requests and limits.
This determines eviction priority when a node is under memory pressure.

| Class | Condition | Eviction priority |
|-------|-----------|-------------------|
| **Guaranteed** | Every container has requests == limits for both CPU and memory | Evicted last |
| **Burstable** | At least one container has a request or limit, but not Guaranteed | Evicted second |
| **BestEffort** | No container has any requests or limits | Evicted first |

The nginx deployment in this experiment is **Burstable** (requests < limits).
The oomkill-demo pod is **Guaranteed** (requests == limits for memory, no CPU limit — actually Burstable).

### CPU units

`100m` = 100 millicores = 0.1 of one CPU core. `1` = 1 full core. `250m` = a quarter core.

---

## Apply

```
kubectl apply -f experiments/06-resource-limits/namespace.yaml && kubectl apply -f experiments/06-resource-limits/
```

## Inspect the well-behaved deployment

```
kubectl get pods -n limits-demo
```

Describe the pod to see its QoS class and resource allocation:

```
kubectl describe pod -n limits-demo -l app=nginx
```

Look for the `QoS Class` field near the bottom. It will show `Burstable` because
requests are lower than limits.

## Read node resource allocation

```
kubectl describe node ipc7
```

Scroll to the `Allocated resources` section. You'll see a table showing how much
CPU and memory is currently requested across all pods on that node, expressed both
as raw values and as a percentage of node capacity. This is what the scheduler
consults — it works from **requests**, not actual usage.

## Observe OOMKill

Apply just the oomkill pod and watch it:

```
kubectl get pod oomkill-demo -n limits-demo --watch
```

The container requests 128M of memory but its limit is 64Mi. The kernel OOM killer
fires almost immediately. You'll see the status go:

```
Pending → ContainerCreating → OOMKilled
```

Once it's in OOMKilled state, describe it:

```
kubectl describe pod oomkill-demo -n limits-demo
```

Look for:

```
Last State:  Terminated
  Reason:    OOMKilled
  Exit Code: 137
```

Exit code 137 = killed by signal 9 (SIGKILL). The `restartPolicy: Never` means it
stays in OOMKilled state rather than restarting, so you can inspect it clearly.

## Observe an unschedulable pod

```
kubectl get pod unschedulable-demo -n limits-demo --watch
```

It will stay `Pending`. Describe it:

```
kubectl describe pod unschedulable-demo -n limits-demo
```

In the `Events` section:

```
Warning  FailedScheduling  default-scheduler  0/3 nodes are available:
  3 Insufficient cpu, 3 Insufficient memory.
```

The scheduler evaluated all three nodes and found none with 100 CPUs and 500Gi free.
The pod sits in the queue indefinitely — it never reaches a node. No containers are
created, no images are pulled.

## QoS class comparison

Check the QoS class of each pod:

```
kubectl get pod -n limits-demo -o custom-columns="NAME:.metadata.name,QOS:.status.qosClass"
```

## Teardown

```
kubectl delete namespace limits-demo
```
