# Experiment 32 — KubeVirt VM Integration Tests

Experiment 29 proved we can build Pelagos in-cluster and run 463/478 integration
tests by SSHing back to ipc7. The 4 remaining failures are port-forward and
localhost-proxy tests that need an isolated network namespace — the VM's loopback
is shared with ipc7's production kernel when running directly on the host.

This experiment runs the same pre-compiled test binary inside a KubeVirt VM on ipc7.
The VM gets its own kernel and isolated network namespace, giving pasta a clean
loopback for its proxy relay. Result: **467/478 tests pass** (all 4 originally-failing
port-forward tests fixed; the previously-passing multi_network isolation test also
passes with the kernel module setup below).

## How it works

1. `setup.sh` (run as root on ipc7) creates two tarballs from the existing build
   cache (`/srv/pelagos-build/cache/`) and starts a temporary HTTP server on port 9080.
2. A KubeVirt VMI boots on ipc7 using Ubuntu 24.04.
3. The VM uses masquerade networking. Inside the VM, ipc7's node IP (192.168.88.63)
   is reachable via the pod's NAT — so the VM can HTTP-download the test artifacts.
4. cloud-init installs `passt`, `gcc`, `nftables`, `rsync`, and `wget`, then runs
   `/usr/local/bin/run-pelagos-tests.sh` which downloads the test binary, sets up
   symlinks, loads kernel modules, and runs the tests. Output goes to the serial console.
5. The VM powers off when the test run completes.
6. `teardown.sh` (run as root on ipc7) stops the HTTP server.

## Required kernel setup in the VM

Two modules must be loaded before running tests:

- **`overlay`** — Ubuntu 24.04 cloud image doesn't load it by default; Pelagos needs it
  for overlayfs container layers.
- **`br_netfilter`** — enables bridge traffic to flow through netfilter. The
  `test_multi_network_isolation` test inserts `iptables FORWARD DROP` rules between
  bridges; without this module the rules are ignored and the test fails.

After loading `br_netfilter`, the sysctl `net.bridge.bridge-nf-call-iptables` must be
set to `1` (k3s does this on the host nodes, but not in a fresh VM).

## Files

| File | Purpose |
|------|---------|
| `vmi.yaml` | VirtualMachineInstance manifest |
| `setup.sh` | Run as root on ipc7 before applying VMI — creates tarballs + starts HTTP server |
| `teardown.sh` | Run as root on ipc7 after VMI exits — stops the HTTP server |

## Prerequisites

The experiment 29 build job must have completed successfully first. Verify:

```
ssh -J cb@ipc4.taildd208.ts.net cb@ipc7 "ls /srv/pelagos-build/cache/target/release/deps/integration_tests-* 2>/dev/null | grep -v '.d$'"
```

## Run

**Step 1** — set up ipc7 (creates tarballs + starts HTTP server):

```
ssh -J cb@ipc4.taildd208.ts.net cb@ipc7 "sudo bash -s" < experiments/32-kubevirt-integration-tests/setup.sh
```

**Step 2** — apply the VMI:

```
kubectl apply -f experiments/32-kubevirt-integration-tests/vmi.yaml
```

**Step 3** — watch the serial console (Ctrl-] to detach):

```
virtctl console pelagos-integration-tests
```

The VM boots, installs packages, downloads ~420 MB of test artifacts, then runs the
tests. Expect 15–25 minutes total. Tests run sequentially (--test-threads=1).

To run only a specific test (e.g. while debugging), pass it as a filter in `vmi.yaml`:

```yaml
/cache/target/release/deps/integration_tests --test-threads=1 multi_network_isolation || true
```

Note: the `userData` block has a hard 2048-byte limit, so the script must be kept
compact. The current manifest is ~2020 bytes with the full test suite.

## Observe

Watch VMI phase transitions:

```
kubectl get vmi pelagos-integration-tests -w
```

The VMI transitions: `Scheduling → Running → Succeeded` (or `Failed` if something
goes wrong).

## Teardown

After the VMI reaches Succeeded or Failed:

```
kubectl delete vmi pelagos-integration-tests
ssh -J cb@ipc4.taildd208.ts.net cb@ipc7 "sudo bash -s" < experiments/32-kubevirt-integration-tests/teardown.sh
```

## Expected result

```
test result: ok. 467 passed; 0 failed; 11 ignored; ...
```

The 4 previously failing tests on the host now pass in the VM's isolated network
namespace:
- `networking::test_port_forward_end_to_end`
- `port_proxy::test_port_proxy_localhost_connectivity`
- `port_proxy::test_port_proxy_multiple_connections`
- `ipv6::test_ipv6_port_forward_localhost`

The `multi_network::test_multi_network_isolation` test passes in the VM (required
`br_netfilter` + `net.bridge.bridge-nf-call-iptables=1`). It also passes on the host
(k3s sets these automatically).

The 11 `#[ignore]`-marked tests remain ignored by developer choice.

## Troubleshooting

**VM can't reach HTTP server** — confirm the HTTP server is running on ipc7:

```
ssh -J cb@ipc4.taildd208.ts.net cb@ipc7 "cat /tmp/http-server.pid && curl -s http://192.168.88.63:9080/target/release/pelagos | wc -c"
```

**VMI stuck in Scheduling** — ipc7 must be Ready:

```
kubectl get node ipc7
```

**Package install fails** — the VM needs internet access via the masquerade NAT.
Confirm ipc7's own internet connectivity is up.

**`test_multi_network_isolation` fails** — check that `br_netfilter` loaded and the
sysctl was applied. The cloud-init script runs `modprobe br_netfilter || true` then
`sysctl -w net.bridge.bridge-nf-call-iptables=1` before the test binary. If the
sysctl line is missing or fails, iptables FORWARD DROP rules won't apply to bridged
traffic and the isolation assertion fails.

## Why not virtiofs?

KubeVirt 1.8.4's admission webhook rejects virtiofs for PVC-backed volumes even when
the `Virtiofs` feature gate is enabled. The feature gate only enables virtiofs for
ConfigMap/Secret volumes, not PVCs. The HTTP server approach avoids this restriction
entirely.
