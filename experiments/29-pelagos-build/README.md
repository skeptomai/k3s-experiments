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

## Getting to 467/478 — running tests in a KubeVirt VM

The 4 failures above need an isolated network namespace: pasta's localhost proxy relay
doesn't work when the host's loopback is shared with the test process. The fix is to run
the tests inside a KubeVirt VM, which gets its own kernel and its own loopback.

See **[Experiment 32](../32-kubevirt-integration-tests/README.md)** for the full setup.
The short version:

- A KubeVirt VMI boots on ipc7 with Ubuntu 24.04.
- `setup.sh` in exp 32 tarballs the source tree and alpine rootfs from the build cache
  and starts a temporary HTTP server (`python3 -m http.server 9080`) on ipc7.
- The VM downloads binaries and tarballs from `http://192.168.88.63:9080` via
  KubeVirt's masquerade NAT, sets up the Pelagos install layout, and runs the test
  binary. The VM powers off when the run completes.
- Two kernel modules must be loaded in the VM: `overlay` (not built-in in the Ubuntu
  cloud image) and `br_netfilter` (needed for the bridge isolation test). After loading
  `br_netfilter`, `net.bridge.bridge-nf-call-iptables=1` must be set via sysctl — k3s
  sets this on ipc7 automatically, but a fresh VM doesn't have it.

Result: **467/478 pass, 0 fail, 11 ignored** — 478 total minus 11 developer-`#[ignore]`
tests equals 467 that are expected to pass, and all of them do.

### Note on the 2048-byte cloud-init limit

The VMI manifest embeds the boot script inline in the `userData` field. KubeVirt caps
this at **2048 bytes** because it stores the value in the Kubernetes object (and thus
etcd). This is a KubeVirt-imposed limit, not a cloud-init limitation — cloud-init itself
can handle much larger payloads (AWS user-data is 16 KB; cloud-init supports multi-MB
`#include` chains). KubeVirt's own workaround is `userDataSecretRef`, which points to a
Secret stored separately outside the VMI object.

The exp 32 manifest sits at ~2020 bytes with the full test suite. If you need more room,
move the script to a ConfigMap or Secret and reference it via `userDataSecretRef`.

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
