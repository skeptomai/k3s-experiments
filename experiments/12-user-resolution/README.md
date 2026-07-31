# Experiment 12 — User Resolution from Image Passwd

When a container image specifies a username (rather than a numeric UID) in its OCI config, the container runtime must resolve that name to a UID using the image's own `/etc/passwd` — not the host's. This experiment verifies that Pelagos performs this resolution correctly. The `curlimages/curl` image ships with a `curl_user` account that does not exist on the Ubuntu host nodes, making it a clean test case: if resolution falls back to the host, the container either fails or runs as root.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `user-demo` namespace |
| `job.yaml` | Runs `id` in a `curlimages/curl` container whose OCI config sets `User: curl_user` (string, not UID) |

## Apply

```
kubectl apply -f experiments/12-user-resolution/namespace.yaml
kubectl apply -f experiments/12-user-resolution/job.yaml
```

## Observe

Wait for the Job to complete, then check the output:

```
kubectl wait --for=condition=complete job/user-resolution-test -n user-demo --timeout=60s
kubectl logs -n user-demo -l job-name=user-resolution-test
```

The `id` output should show `uid=100(curl_user)` — confirming Pelagos resolved the username against the image's `/etc/passwd`, not the host's. If user resolution were broken, the container would either fail to start or run as an unexpected UID.

## Teardown

```
kubectl delete namespace user-demo
```
