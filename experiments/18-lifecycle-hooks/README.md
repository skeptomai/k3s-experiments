# Experiment 18 — Container Lifecycle Hooks

Kubernetes gives containers two hook points — `postStart` and `preStop` — that let you run code at the edges of a container's life without modifying the application image. This experiment demonstrates both: a postStart hook that writes a file before the pod is marked Ready, and a preStop hook that writes to a HostPath volume so the evidence survives after the pod is gone. Understanding these hooks is essential for zero-downtime deployments, because missing a preStop drain step is one of the most common sources of dropped connections during rolling updates.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `hooks-demo` namespace |
| `pod-poststart.yaml` | Pod with a `postStart` exec hook that writes `/tmp/hook-proof` before Ready |
| `pod-prestop.yaml` | Pod pinned to ipc4 with a `preStop` exec hook that writes to a HostPath volume |

## Apply

```
kubectl apply -f experiments/18-lifecycle-hooks/
```

## Observe

1. Wait for both pods to be Ready, then check that postStart ran before the pod was marked Ready:

   `kubectl wait pod/poststart-demo -n hooks-demo --for=condition=ready --timeout=30s && kubectl exec -n hooks-demo poststart-demo -- cat /tmp/hook-proof`

   Expected output: `poststart-ran`

2. Delete the preStop pod with a short grace period and immediately check the evidence file on ipc4. The file must exist even though the pod is gone — preStop completed before SIGTERM was sent:

   `kubectl delete pod prestop-demo -n hooks-demo --grace-period=10 && ssh cb@ipc4.taildd208.ts.net "cat /tmp/hooks-demo-prestop/prestop-proof"`

   Expected output: `prestop-ran`

3. The termination sequence is: preStop runs → SIGTERM sent to PID 1 → SIGKILL after `terminationGracePeriodSeconds` if still alive. If preStop plus normal shutdown exceed the grace period, SIGKILL fires regardless — keep preStop short or raise `terminationGracePeriodSeconds`.

## Teardown

`kubectl delete namespace hooks-demo`

Clean up the HostPath evidence directory on ipc4: `ssh cb@ipc4.taildd208.ts.net "rm -rf /tmp/hooks-demo-prestop"`
