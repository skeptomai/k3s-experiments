# Pelagos as a k3s Container Runtime

## Goal

Replace or augment containerd in k3s with [pelagos](https://github.com/pelagos-containers/pelagos),
a daemonless Rust container runtime. This doc maps out the integration paths, their prerequisites,
and the key concept gap that applies to all of them.

## Current pelagos capabilities relevant to k3s

| Capability | Status | Notes |
|-----------|--------|-------|
| OCI Runtime Spec (`create/start/state/kill/delete`) | Complete | The low-level lifecycle k8s ultimately calls |
| containerd shim v2 (ttrpc) | Complete for Wasm | `containerd-shim-pelagos-wasm-v1`; pattern exists for Linux |
| OCI image pull / manage | Complete | `pelagos image pull/ls/rm` |
| Networking (bridge, NAT, port mapping, DNS) | Complete | Native nftables, no CNI plugin |
| Cgroups v2 resource limits | Complete | Memory, CPU, PID limits |
| `pelagos-dockerd` | Complete | Docker Engine API shim — not directly useful for k3s |
| runc parity | ~80% | Remaining gaps: AppArmor/SELinux, CRIU, some OCI config fields |

## The critical concept gap: pod sandbox

In Kubernetes, every pod runs inside a **sandbox** — a pause container whose only job is to hold
the shared Linux namespaces (network, IPC, UTS) for that pod. All other containers in the pod
join those namespaces rather than creating their own. The pause container lives for the pod's
entire lifetime; individual app containers can restart without losing the pod's IP address or
network state.

Pelagos has no equivalent concept today. It treats every container as an independent unit with
its own namespace lifecycle. This gap affects all three integration paths differently:

- **Paths 1 and 2** — containerd handles the sandbox; pelagos only sees individual container exec
- **Path 3** — pelagos must implement sandbox creation and namespace sharing itself

---

## Integration path 1: OCI runtime plugin (least effort)

**How it works:** k3s embeds containerd. Containerd can delegate low-level container execution
to any OCI-compatible runtime binary via its `runc.v2` shim. You add a stanza to containerd's
config pointing at the `pelagos` binary, then create a Kubernetes `RuntimeClass` that selects it.
Containerd still handles all CRI-level work (pod sandboxes, image pulls, pod networking via Flannel).
Pelagos handles `create/start/state/kill/delete` for each container.

**What already works:** pelagos implements the OCI Runtime Spec. No new code is required to try this.

**Steps:**

1. Build and install `pelagos` on each k3s node (`scripts/install.sh` from the pelagos repo)
2. Edit the k3s containerd config on each node at `/var/lib/rancher/k3s/agent/etc/containerd/config.toml`
   and add a runtime stanza:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.pelagos]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.pelagos.options]
    BinaryName = "/usr/local/bin/pelagos"
```

3. Restart k3s on the node
4. Create a `RuntimeClass` in the cluster:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: pelagos
handler: pelagos
```

5. Schedule a pod with `runtimeClassName: pelagos` and observe pelagos handling the exec layer

**Limitations:**
- Containerd still owns pod sandbox, image management, and network setup
- Pelagos's own networking stack is bypassed — Flannel handles pod networking as usual
- This is a useful proof-of-concept and smoke test, not a full replacement

---

## Integration path 2: containerd shim v2 for Linux containers (moderate effort)

**How it works:** Instead of going through the `runc.v2` OCI shim, pelagos implements the
containerd shim v2 ttrpc protocol directly — the same protocol already implemented in
`containerd-shim-pelagos-wasm-v1`. A new binary `containerd-shim-pelagos-v1` (or
`containerd-shim-pelagos-linux-v1`) handles the ttrpc calls from containerd and drives
pelagos container lifecycle.

**What already exists:** The Wasm shim (`src/bin/pelagos-shim-wasm.rs`) implements the full
shim v2 ttrpc handshake, `Create`/`Start`/`Kill`/`Delete`/`Wait`/`Exec` RPCs, and the
`connect`/`shutdown` lifecycle. The Linux shim would follow the same structure, replacing
the Wasm dispatch with standard pelagos `Command` spawning.

**Steps:**

1. Add `src/bin/pelagos-shim-linux.rs` modelled on the Wasm shim
2. Build and install as `containerd-shim-pelagos-v1` on each node
3. Register in containerd config as `io.containerd.pelagos.v1`
4. Create a `RuntimeClass` selecting the handler

**Advantages over Path 1:**
- More direct integration — containerd doesn't insert an extra OCI shim layer
- Pelagos controls more of the container lifecycle (stdio relay, exit code reporting)
- Same architecture as the already-working Wasm shim

**Limitations:**
- Containerd still owns pod sandbox and network setup
- Linux shim is new code, albeit with a clear template

---

## Integration path 3: full CRI server (significant work)

**How it works:** Pelagos implements the Kubernetes CRI gRPC API and exposes it on a Unix
socket. k3s is configured with `--container-runtime-endpoint unix:///run/pelagos/cri.sock`.
Containerd is removed from the stack entirely. Pelagos handles everything: pod sandboxes,
image pulls, container lifecycle, exec, log streaming, and metrics.

**The CRI API surface:**

The CRI defines two gRPC services in `k8s.io/cri-api`:

| Service | Key RPCs |
|---------|---------|
| `RuntimeService` | `RunPodSandbox`, `StopPodSandbox`, `RemovePodSandbox`, `ListPodSandbox`, `CreateContainer`, `StartContainer`, `StopContainer`, `RemoveContainer`, `ListContainers`, `ContainerStatus`, `ExecSync`, `Exec`, `Attach`, `PortForward`, `UpdateContainerResources`, `ReopenContainerLog` |
| `ImageService` | `PullImage`, `ListImages`, `ImageStatus`, `RemoveImage`, `ImageFsInfo` |

**The pod sandbox work:** This is the core new capability pelagos would need.
`RunPodSandbox` must:
- Pull and start the pause container image (`registry.k8s.io/pause:3.x`)
- Create a network namespace for the pod
- Invoke the CNI plugin (Flannel in k3s) to configure the pod's network interface and IP
- Return a sandbox ID that subsequent `CreateContainer` calls reference
- Share the sandbox's network/IPC/UTS namespaces with each container in the pod via `setns()`

Pelagos already has `setns()` support (used in `pelagos exec`) and namespace sharing primitives.
The CNI plugin invocation would be new — pelagos currently manages networking natively without
CNI, but `RunPodSandbox` must call CNI to stay compatible with k3s's Flannel overlay network.

**Implementation sketch for pod sandbox:**

```rust
// RuntimeService::RunPodSandbox
// 1. Create a named network namespace: ip netns add pelagos-<sandbox-id>
// 2. Call CNI ADD with the pod metadata → Flannel assigns a pod IP
// 3. Start the pause container in that netns (just sleeps forever)
// 4. Store sandbox state: netns path, pause PID, pod IP

// RuntimeService::CreateContainer
// 1. Look up sandbox state by sandbox_id
// 2. Spawn the container with setns() into the sandbox's net/ipc/uts namespaces
// 3. Container gets the pod IP — no separate network setup needed
```

**Steps:**

1. Add `tonic` + `prost` dependencies for gRPC
2. Generate Rust stubs from the CRI proto files (`k8s.io/cri-api/pkg/apis/runtime/v1/`)
3. Implement `RuntimeService` — start with `RunPodSandbox`, `CreateContainer`, `StartContainer`,
   `StopContainer`, `RemoveContainer`, `ExecSync`
4. Implement `ImageService` — wrap existing `pelagos image pull/ls/rm`
5. Add CNI invocation in `RunPodSandbox` for Flannel compatibility
6. Configure k3s: add `--container-runtime-endpoint` to the k3s service args on each node

**Advantages:**
- Pelagos fully owns the runtime stack — no containerd in the chain
- Pelagos's security defaults (seccomp, cap-drop, no-new-privs) apply to every pod automatically
- Foundation for running Wasm and Linux workloads through one unified runtime

**Limitations:**
- Most work of the three paths
- CNI integration is new territory for pelagos (it currently manages networking natively)
- Must pass the Kubernetes node conformance tests before k3s will trust it with production pods

---

## Recommended sequence

1. **Path 1 first** — validate that pelagos's OCI Runtime Spec implementation works under
   real k3s workloads. Find and fix any gaps in `create/start/state/kill/delete` handling.
   This de-risks Paths 2 and 3.

2. **Path 2 next** — build the Linux shim using the Wasm shim as a template. This gives
   pelagos direct stdio/exit-code control and validates the ttrpc integration.

3. **Path 3 when ready** — the full CRI server, starting with pod sandbox, is the end goal.
   The CNI work and conformance testing are the long poles.

The pod sandbox primitive is tracked as a standalone pelagos issue:
[pelagos#234 — feat(sandbox): pod sandbox — named namespace group for multi-container sharing](https://github.com/pelagos-containers/pelagos/issues/234)

---

## k3s cluster reference

- containerd config on nodes: `/var/lib/rancher/k3s/agent/etc/containerd/config.toml`
- k3s service args (to add `--container-runtime-endpoint`): `/etc/systemd/system/k3s.service` (ipc1) and `/etc/systemd/system/k3s-agent.service` (ipc2, ipc3)
- CRI socket (current): `/run/k3s/containerd/containerd.sock`
- Pelagos repo: `~/Projects/pelagos` (local), `https://github.com/pelagos-containers/pelagos`
