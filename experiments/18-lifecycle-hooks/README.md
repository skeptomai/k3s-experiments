# Experiment 18: Container Lifecycle Hooks

## What you'll observe

- A `postStart` exec hook running immediately after container start, before the pod is marked Ready
- A `preStop` exec hook running before the container receives SIGTERM during pod deletion
- That preStop completes before the pod is removed (evidence file persists after pod is gone)

## Concepts

### postStart

Called by the kubelet immediately after the container starts. The container is **not** marked Ready until postStart completes. If postStart fails (non-zero exit), the container is killed and restarts.

Common uses: wait for a sidecar to be ready, register with a service catalog, warm a local cache.

```yaml
lifecycle:
  postStart:
    exec:
      command: ["sh", "-c", "until curl -sf http://localhost:8080/ready; do sleep 1; done"]
```

### preStop

Called by the kubelet before sending SIGTERM to the container. The kubelet waits for preStop to complete (up to `terminationGracePeriodSeconds`), then sends SIGTERM, then SIGKILL after the grace period.

Common uses: drain in-flight requests, deregister from a load balancer, flush write buffers.

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "/app/drain-connections && sleep 5"]
```

### Relationship to SIGTERM

The sequence on pod deletion:
1. preStop hook runs (if defined)
2. SIGTERM sent to PID 1
3. Process has `terminationGracePeriodSeconds - preStop duration` remaining
4. SIGKILL if still alive after grace period

If preStop + process shutdown exceed `terminationGracePeriodSeconds`, SIGKILL fires regardless.

### Pelagos note

Both hook types are implemented and verified working as of Pelagos v0.65.29 ([#329](https://github.com/pelagos-containers/pelagos/issues/329)).

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `hooks-demo` namespace |
| `pod-poststart.yaml` | postStart hook writes `/tmp/hook-proof`; exec into pod to verify |
| `pod-prestop.yaml` | preStop hook writes to a HostPath volume; file survives pod deletion |

## Running manually

```
kubectl apply -f experiments/18-lifecycle-hooks/

# Verify postStart ran
kubectl wait pod/poststart-demo -n hooks-demo --for=condition=ready --timeout=30s
kubectl exec -n hooks-demo poststart-demo -- cat /tmp/hook-proof
# → poststart-ran

# Verify preStop runs before termination (evidence file on ipc4 at /tmp/hooks-demo-prestop/)
kubectl wait pod/prestop-demo -n hooks-demo --for=condition=ready --timeout=30s
kubectl delete pod prestop-demo -n hooks-demo --grace-period=10
ssh cb@ipc4.taildd208.ts.net "cat /tmp/hooks-demo-prestop/prestop-proof"
# → prestop-ran
```
