# Experiment 29 — In-Cluster Pelagos Build

Pelagos is both the container runtime for the cluster and a binary that can build OCI
images — which means you can build Pelagos itself inside the cluster it runs. This
experiment demonstrates that capability: a Kubernetes Job runs a pre-built builder image,
clones the Pelagos source at a pinned Git ref, compiles both the `pelagos` and
`pelagos-cri` binaries with Cargo, runs unit tests and integration tests, and drops the
resulting binaries into a hostPath volume on ipc7 for immediate use. The build cache
(Cargo registry and compiled artifacts) persists across runs on the same node, making
incremental builds fast (~40s on a warm cache).

## Files

| File | Purpose |
|------|---------|
| `build-job.yaml` | Batch Job that compiles `pelagos` and `pelagos-cri` from a pinned Git ref inside the cluster |

## Prerequisites on ipc7

Before running the build job for the first time, create the alpine rootfs on ipc7 (used
by integration tests). SSH to ipc7 and run once:

```
sudo mkdir -p /srv/pelagos-build/alpine-rootfs && curl -fsSL https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-minirootfs-3.21.0-x86_64.tar.gz | sudo tar xz -C /srv/pelagos-build/alpine-rootfs
```

## Apply

Update `GIT_REF` in `build-job.yaml` to the target version, then apply:

```
kubectl apply -f experiments/29-pelagos-build/build-job.yaml
```

## Observe

Watch the build log in real time (replace the version in the job name to match):

```
kubectl logs -f job/pelagos-build-v0-65-73
```

The job:
1. Fetches/clones the repo into `/cache/repo` on ipc7
2. Builds in release mode (`cargo build --release`)
3. Runs `cargo test --lib` (unit tests, 393/395 in v0.65.73)
4. Installs binaries to `/srv/pelagos-build/out/` on the node
5. Runs `cargo test --test integration_tests` (full integration suite, requires root + privileged pod)

Integration tests create real containers, cgroups, and loopback network namespaces
inside the pod. The job runs privileged on ipc7 with:
- `/srv/pelagos-build/var-lib-pelagos` as hostPath for `/var/lib/pelagos` (image layers,
  overlay scratch — must be ext4, not container overlay, for kernel overlayfs to work)
- `/run/pelagos` as emptyDir (containers state — same ext4 device, for overlay upper/work)
- `/srv/pelagos-build/alpine-rootfs` as read-only hostPath for `/alpine-rootfs`

**Bridge networking tests (`pasta`) are skipped/failing.** Installing `passt` in-pod
causes a net regression: Debian 12's pasta detects the netns bind-mount differently
than Pelagos expects. Tests that handled `pasta not found` gracefully instead fail with
`pasta found but crashed`. Leave `passt` uninstalled — ~205 of 478 integration tests pass
(all non-bridge-networking functionality).

A successful run ends with:

```
test result: FAILED. NNN passed; MMM failed; ...
```

(The job exits 101 because bridge networking tests fail — expected in-pod.)

Check the output binaries on ipc7:

```
kubectl get job pelagos-build-v0-65-73 -o wide
```

Then SSH to ipc7 and inspect the artifacts at `/srv/pelagos-build/out/`.

## Teardown

```
kubectl delete job pelagos-build-v0-65-73
```

The hostPath cache at `/srv/pelagos-build/cache` on ipc7 is intentionally left in place — it makes the next build faster. Remove it manually on the node if disk space is a concern.
