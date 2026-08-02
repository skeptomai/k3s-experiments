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

**Once only — create the alpine rootfs** (used by integration tests):

```
ssh -J cb@ipc4.taildd208.ts.net cb@ipc7 "sudo mkdir -p /srv/pelagos-build/alpine-rootfs && curl -fsSL https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-minirootfs-3.21.0-x86_64.tar.gz | sudo tar xz -C /srv/pelagos-build/alpine-rootfs"
```

**Once only — create the SSH key Secret** (build pod SSHes back to ipc7 to run tests):

```
kubectl create secret generic pelagos-build-ssh-key --from-file=id_rsa=$HOME/.ssh/id_rsa
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
5. Compiles the integration test binary in-pod (`--no-run`)
6. SSHes back to ipc7 and runs `scripts/run-integration-tests.sh` as root

Integration tests run **directly on ipc7** (not inside a container) so that bridge
networking and network namespace operations work without the nested-container restriction.
`scripts/run-integration-tests.sh` creates a `/cache` symlink so that compile-time-baked
paths in the test binary resolve correctly, then runs the pre-compiled binary from
`/srv/pelagos-build/cache/target/release/deps/`.

Note: tests use `/var/lib/pelagos` and `/run/pelagos` from ipc7's production Pelagos
installation. Avoid running the build job while heavy workloads are on ipc7.

A successful run ends with something like:

```
test result: FAILED. 463 passed; 4 failed; 11 ignored; ...
```

The 4 remaining failures are port-forward/localhost-proxy tests
(`networking::test_port_forward_end_to_end`, `port_proxy::test_port_proxy_localhost_connectivity`,
`port_proxy::test_port_proxy_multiple_connections`, `ipv6::test_ipv6_port_forward_localhost`).
They establish connections (pasta works) but get empty responses — a host-networking
difference when running directly on ipc7 vs in an isolated network namespace. These are
not regressions; they have never passed in this environment.

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
