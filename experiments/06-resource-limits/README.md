# Experiment 06 — Resource Limits

Kubernetes lets you declare how much CPU and memory each container expects (requests) and
the hard ceiling it may never exceed (limits). Requests drive scheduling — the scheduler
only places a pod on a node that has enough unallocated capacity. Limits drive enforcement
at runtime — the kernel OOM-kills a container that exceeds its memory limit and throttles
one that exceeds its CPU limit. This experiment makes both behaviors concrete: a
well-behaved nginx deployment, a pod that gets OOMKilled immediately, and a pod with
impossible requests that sits Pending forever.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `limits-demo` namespace |
| `deployment.yaml` | nginx Deployment with requests below limits (Burstable QoS) |
| `pod-oomkill.yaml` | Pod that allocates 200MB into a 64Mi memory limit — triggers OOMKill |
| `pod-unschedulable.yaml` | Pod requesting 100 CPUs and 500Gi memory — stays Pending indefinitely |
| `how-limits-work.md` | Deep dive into cgroups enforcement: cpu.weight, cpu.max, memory.max |

## Apply

```
kubectl apply -f experiments/06-resource-limits/namespace.yaml && kubectl apply -f experiments/06-resource-limits/
```

## Observe

### QoS class and resource allocation

Describe the nginx pod to see its QoS class:

```
kubectl describe pod -n limits-demo -l app=nginx
```

The `QoS Class` field near the bottom shows `Burstable` — requests are lower than limits.
A pod is `Guaranteed` only when every container has requests equal to limits for both CPU
and memory. A pod with no requests or limits at all is `BestEffort`, evicted first under
memory pressure.

### Node resource allocation

```
kubectl describe node <node-name>
```

The `Allocated resources` table shows how much CPU and memory is currently requested
across all pods on that node, as raw values and as a percentage of capacity. This is
what the scheduler consults — actual usage is irrelevant; only requests matter for
placement.

Get a node name with `kubectl get nodes`.

### OOMKill

Watch the oomkill pod:

```
kubectl get pod oomkill-demo -n limits-demo --watch
```

The container tries to hold 200MB in memory against a 64Mi limit. The kernel OOM killer
fires as soon as the cgroup hits `memory.max`. You'll see the pod go `OOMKilled` almost
immediately. Check the exit code:

```
kubectl describe pod oomkill-demo -n limits-demo
```

Look for `Exit Code: 137` and `Reason: OOMKilled` in the container state.

### Unschedulable pod

```
kubectl describe pod unschedulable-demo -n limits-demo
```

The `Events` section will show `FailedScheduling` with a message like `0/6 nodes are
available: Insufficient cpu, Insufficient memory`. The pod stays `Pending` until either
nodes with enough capacity appear or the pod is deleted.

## Teardown

```
kubectl delete namespace limits-demo
```
