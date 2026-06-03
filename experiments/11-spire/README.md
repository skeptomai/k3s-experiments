# Experiment 11: SPIRE — Node and Workload Attestation

## What you'll observe

- SPIRE Server running as a StatefulSet with NFS-backed persistent storage, acting as the cluster's SPIFFE CA
- SPIRE Agent running as a DaemonSet on every node, attesting itself to the server via Kubernetes Projected Service Account Tokens (k8s_psat)
- A workload fetching an X.509 SVID from the SPIFFE Workload API, proving its identity without any secrets injected at deploy time
- mTLS between two workloads using SVIDs — mutual authentication with zero pre-shared secrets

## Concepts

**SPIFFE** (Secure Production Identity Framework for Everyone) defines a standard for workload identity. Every workload gets a SPIFFE ID of the form `spiffe://<trust-domain>/<path>`, encoded in an X.509 certificate called an SVID (SPIFFE Verifiable Identity Document).

**SPIRE** (SPIFFE Runtime Environment) is the reference implementation. It has two components:

```
SPIRE Server  — the CA; issues SVIDs; stores state (CA key, registration entries)
SPIRE Agent   — runs on every node; attests the node to the server; issues SVIDs
                to local workloads via the Workload API Unix socket
```

**Attestation** is how SPIRE establishes trust without pre-shared secrets:

- **Node attestation**: the Agent proves to the Server that it is running on a legitimate cluster node. On bare metal k3s (no cloud instance identity), we use the `k8s_psat` attestor — the Agent presents a Kubernetes Projected Service Account Token; the Server validates it against the Kubernetes API.
- **Workload attestation**: the Agent proves to a workload's process which pod it belongs to. The `k8s` workload attestor interrogates the CRI (via the container runtime socket) to map the calling process's PID to a pod, then matches that pod against registration entries.

**Registration entries** bind a SPIFFE ID to a selector set. Example: "any pod in namespace `spire-demo` with service account `demo-sa` gets the SVID `spiffe://ipc.local/demo-app`."

**Trust domain**: this cluster uses `ipc.local`.

## Trust posture and the server's position in the chain

The SPIRE Server is a **Trusted Computing Base (TCB)** component — it is the root of trust, not a participant in the attestation chain it operates. It does not attest itself to anything; it is trusted implicitly because it runs under a Kubernetes service account (`spire-server`) with tightly scoped RBAC.

This means the server's trust is entirely derived from Kubernetes: if the `spire` namespace or the `spire-server` service account is compromised, the CA is compromised. This is the standard SPIRE deployment model and an accepted posture when the Kubernetes control plane itself is the security boundary.

**What we attest:** agents (via `k8s_psat`) and workloads (via the `k8s` workload attestor). The server is unattested.

**How to harden this if needed:**
- **Upstream CA**: configure SPIRE with an external CA (e.g. HashiCorp Vault, AWS PCA). The server's signing key material comes from outside the cluster — compromising the server pod doesn't yield a usable CA key.
- **Nested SPIRE**: a root SPIRE deployment attests the cluster SPIRE server itself, issuing it an SVID. Used in multi-cluster or multi-cloud federations.

For this cluster, the control plane is the trust anchor and that is a deliberate, reasonable position.

## Architecture on this cluster

```
ipc1 (control-plane)          ipc2, ipc3 (workers)
┌─────────────────────┐       ┌──────────────────────────┐
│ spire-server-0      │       │ spire-agent (DaemonSet)   │
│ StatefulSet         │◄──────│ node attestation via psat │
│ NFS PVC (CA state)  │       │ workload attestation via  │
│ port 8081           │       │ /run/pelagos/cri.sock     │
└─────────────────────┘       │                          │
                              │ /run/spire/sockets/       │
                              │   agent.sock (Workload API│
                              │   mounted into pods)      │
                              └──────────────────────────┘
```

**Pelagos note**: see "Pelagos compatibility" section below for the two issues encountered and how they were resolved.

## Phases

### Phase 1 — SPIRE Server and Agent running (this experiment)
- Namespace, RBAC, ConfigMaps
- SPIRE Server as StatefulSet with NFS PVC
- SPIRE Agent as DaemonSet with k8s_psat node attestation
- Verify: `spire-server healthcheck` and `spire-agent healthcheck` both pass
- Verify: all three nodes show as attested in `spire-server agent list`

### Phase 2 — Workload identity ✓

The demo workload successfully fetches an X.509 SVID from the SPIFFE Workload API. The SVID is issued by the SPIRE server, signed with the cluster's trust domain CA (`ipc.local`), and carries the SPIFFE ID `spiffe://ipc.local/demo-app`. See "Pelagos compatibility" below for the two issues encountered during implementation.

Apply manifests:
1. `kubectl apply -f experiments/11-spire/demo-namespace.yaml`
2. `kubectl apply -f experiments/11-spire/demo-registration-rbac.yaml`
3. `kubectl apply -f experiments/11-spire/demo-registration-job.yaml`
4. Wait for job to complete, then: `kubectl apply -f experiments/11-spire/demo-workload.yaml`
5. `kubectl logs -n spire-demo demo-workload`

Expected output includes:
```
Received 1 svid after 2.015399ms

SPIFFE ID:    spiffe://ipc.local/demo-app
SVID Valid After:  2026-06-02 20:41:13 +0000 UTC
SVID Valid Until:  2026-06-02 21:41:23 +0000 UTC
...
URI:spiffe://ipc.local/demo-app
```

## Pelagos compatibility

Two issues were encountered with the Pelagos container runtime.

### Issue 1: hostPID not implemented (Pelagos #299, fixed in v0.65.7)

SPIRE's k8s workload attestor reads `SO_PEERCRED` on the Workload API Unix socket to get the calling process's PID, then resolves that PID against `/proc/<pid>/cgroup`. This requires the agent to share the **host PID namespace** (`hostPID: true`) so that workload PIDs are visible from the agent.

Pelagos v0.65.6 ignored the `hostPID` field (CRI: `namespace_options.pid = NODE`) and isolated every container into its own PID namespace. `SO_PEERCRED` returned PID 0 (cross-namespace), which SPIRE rejected.

**Fix**: Pelagos v0.65.7 implements `hostPID: true` via a `--no-pid-ns` flag. Verified via `NSpid` in `/proc/<pid>/status` — the agent now shows a single entry (initial namespace).

### Issue 2: 32-char container IDs incompatible with SPIRE's k8s WorkloadAttestor (fixed in Pelagos v0.65.8)

After fixing hostPID, workload attestation still failed with `no identity issued`. Enabling `verbose_container_locator_logs = true` revealed:

```
PID cgroup enumerated path=/../../pod<uid>/<32-char-id>
PID attested to have selectors selectors="[]"
```

SPIRE's `pkg/common/containerinfo/extract.go` uses a hardcoded regex requiring exactly 64-char hex container IDs — the de facto standard set by containerd and CRI-O, which generate IDs as 32 random bytes encoded as hex. Pelagos was generating IDs using `uuid::Uuid::new_v4().simple()` (128-bit UUID, 32 hex chars), which is incompatible with SPIRE and the broader ecosystem (Fluentd, Fluent Bit, OpenTelemetry, Datadog, Falco all share the same assumption).

Filed as [Pelagos #301](https://github.com/pelagos-containers/pelagos/issues/301). Fixed in Pelagos v0.65.8: container and sandbox IDs are now generated as 32 random bytes via `/dev/urandom`, hex-encoded to 64 characters — matching containerd/CRI-O exactly.

### Phase 3 — mTLS between workloads (follow-on experiment)
- Two services; each gets a SPIFFE ID
- Envoy or spiffe-helper sidecar handles cert rotation and presents the SVID for mTLS
- No secrets, no cert management — identity is purely attestation-derived

## Deployment

SPIRE server and agents are **infrastructure**, managed by Flux from `manifests/spire/`. Committing changes to those manifests is sufficient — Flux reconciles the cluster within minutes.

The demo workload and registration entries are separate:

```
kubectl apply -f experiments/11-spire/demo-namespace.yaml
kubectl apply -f experiments/11-spire/demo-registration-rbac.yaml
kubectl apply -f experiments/11-spire/demo-registration-job.yaml
```

Wait for the registration job to complete, then:

```
kubectl apply -f experiments/11-spire/demo-workload.yaml
```

Note: `demo-registration-job.yaml` is imperative — it runs `spire-server entry create` to write registration entries into SPIRE's internal SQLite database. Re-run it if entries are lost (e.g. after a SPIRE server restart with a wiped PVC). See backlog for the GitOps-native alternative (SPIRE Controller Manager).

## Verify

Check server health: `kubectl exec -n spire statefulset/spire-server -- /opt/spire/bin/spire-server healthcheck`

List attested nodes: `kubectl exec -n spire statefulset/spire-server -- /opt/spire/bin/spire-server agent list`

Check agent health on a node: `kubectl exec -n spire daemonset/spire-agent -- /opt/spire/bin/spire-agent healthcheck`

## Key configuration decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Node attestor | `k8s_psat` | No TPM, no cloud — PSAT is the standard for bare-metal k3s |
| Workload attestor | `k8s` | Maps PID → pod via kubelet API; requires host PID namespace |
| Container locator | `use_new_container_locator=true` | New locator tries mountinfo first, falls back to cgroup |
| `hostPID` support | Fixed in Pelagos v0.65.7 | v0.65.6 isolated every container; v0.65.7 implements `--no-pid-ns` for `hostPID: true` pods |
| Trust domain | `ipc.local` | Matches cluster naming convention |
| CA storage | NFS PVC | Persistent across server restarts; only storage class available |
| Server port | 8081 | SPIRE default |
| Workload API socket | `/run/spire/sockets/agent.sock` | Mounted into workload pods via hostPath |
