# Experiment 08: Liveness and Readiness Probes

## What you'll observe

- A liveness probe failing → container killed and restarted (RESTARTS counter climbs)
- A readiness probe failing → pod stays Running but receives no traffic (0/1 Ready)
- A Service that only routes to pods whose readiness probe is passing
- The critical difference: liveness kills, readiness just cuts traffic

## Concepts

### Probe types

| Type | How it checks | Success condition |
|------|--------------|------------------|
| `exec` | Runs a command inside the container | Exit code 0 |
| `httpGet` | HTTP GET to a path and port | Status code 2xx or 3xx |
| `tcpSocket` | Opens a TCP connection to a port | Connection accepted |

### Probe parameters

| Parameter | Meaning | Default |
|-----------|---------|---------|
| `initialDelaySeconds` | Wait this long after container starts before first probe | 0 |
| `periodSeconds` | How often to probe | 10 |
| `failureThreshold` | Consecutive failures before action is taken | 3 |
| `successThreshold` | Consecutive successes to flip back to healthy | 1 |
| `timeoutSeconds` | How long to wait for a probe response | 1 |

### Liveness vs Readiness vs Startup

| Probe | On failure | Use case |
|-------|-----------|---------|
| **Liveness** | Container is killed and restarted | Detect deadlocks, infinite loops — cases where the process is running but stuck |
| **Readiness** | Pod removed from Service endpoints, not restarted | App is up but not ready yet — warming caches, waiting for a dependency |
| **Startup** | Container is killed and restarted | Slow-starting containers — disables liveness until the app has had time to start |

A startup probe is used to give a slow application extra time to initialise without
triggering the liveness probe prematurely. Once the startup probe succeeds once,
it hands off to the liveness probe.

---

## Apply

```
kubectl apply -f experiments/08-probes/namespace.yaml && kubectl apply -f experiments/08-probes/
```

## Observe the liveness probe failing

Watch the liveness-demo pod:

```
kubectl get pods -n probes-demo --watch
```

The busybox container creates `/tmp/healthy` on start, sleeps 30 seconds, then
deletes it. The liveness probe runs `cat /tmp/healthy` every 5 seconds. After the
file is deleted, 3 consecutive failures (15 seconds) trigger a restart.

You'll see `RESTARTS` increment roughly every 45 seconds. Let it cycle a few times,
then describe the pod to see the restart history:

```
kubectl describe pod -n probes-demo -l app=liveness-demo
```

Look for the `Events` section:

```
Warning  Unhealthy  Liveness probe failed: cat: can't open '/tmp/healthy': No such file or directory
Normal   Killing    Container busybox failed liveness probe, will be restarted
```

## Observe the readiness probe difference

```
kubectl get pods -n probes-demo -l app=readiness-demo
```

You'll see:

```
NAME                             READY   STATUS    RESTARTS
readiness-ok-xxx                 1/1     Running   0
readiness-fail-xxx               0/1     Running   0
```

Both are `Running` — neither is being killed. But `readiness-fail` shows `0/1`: the
container is alive but the pod is not ready. Its readiness probe is hitting `/healthz`,
which nginx doesn't serve (404). The `readiness-ok` pod probes `/` which returns 200.

## Observe the Service endpoints

```
kubectl get endpoints readiness-demo -n probes-demo
```

The Service selects both pods (both have `app: readiness-demo`) but only the ready
pod appears in the endpoints list. Traffic sent to the Service will only reach
`readiness-ok`.

Describe the failing pod to see the probe events:

```
kubectl describe pod -n probes-demo -l variant=fail
```

In Events:

```
Warning  Unhealthy  Readiness probe failed: HTTP probe failed with statuscode: 404
```

Note: no `Killing` event. The pod is never restarted — it just stays out of the
endpoints until its readiness probe passes.

## Startup probe (concept)

For a slow-starting application, a startup probe prevents liveness from restarting
the container before it has had a chance to initialise:

```yaml
startupProbe:
  httpGet:
    path: /healthz
    port: 8080
  failureThreshold: 30
  periodSeconds: 10
```

This gives the app up to 300 seconds (30 × 10) to pass its first health check.
Once it does, the startup probe disables itself and the liveness probe takes over.
Without a startup probe, a slow app would be killed and restarted repeatedly before
it ever finished starting.

## Teardown

```
kubectl delete namespace probes-demo
```
