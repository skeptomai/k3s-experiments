# Experiment 29 — In-Cluster Pelagos Build

Pelagos is both the container runtime for the cluster and a binary that can build OCI
images — which means you can build Pelagos itself inside the cluster it runs. This
experiment demonstrates that capability: a Kubernetes Job runs a pre-built builder image,
clones the Pelagos source at a pinned Git ref, compiles both the `pelagos` and
`pelagos-cri` binaries with Cargo, runs unit tests, and drops the resulting binaries into
a hostPath volume on ipc7 for immediate use. The build cache (Cargo registry and
compiled artifacts) persists across runs on the same node, making incremental builds fast.

## Files

| File | Purpose |
|------|---------|
| `build-job.yaml` | Batch Job that compiles `pelagos` and `pelagos-cri` from a pinned Git ref inside the cluster |

## Apply

Update `GIT_REF` in `build-job.yaml` to the target version, then apply:

```
kubectl apply -f experiments/29-pelagos-build/build-job.yaml
```

## Observe

Watch the build log in real time:

```
kubectl logs -f job/pelagos-build-v0-65-63
```

The job clones (or fetches) the repo into `/cache/repo` on ipc7, builds in release mode,
runs lib tests, and installs the binaries to `/srv/pelagos-build/out/` on the node. A
successful run ends with:

```
==> done: /out/pelagos /out/pelagos-cri
```

Check the output binaries on ipc7:

```
kubectl get job pelagos-build-v0-65-63 -o wide
```

Then SSH to ipc7 and inspect the artifacts at `/srv/pelagos-build/out/`.

## Teardown

```
kubectl delete job pelagos-build-v0-65-63
```

The hostPath cache at `/srv/pelagos-build/cache` on ipc7 is intentionally left in place — it makes the next build faster. Remove it manually on the node if disk space is a concern.
