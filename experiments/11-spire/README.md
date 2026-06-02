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

**Pelagos note**: the k8s workload attestor needs to talk to the CRI socket to resolve PIDs to pods. This cluster uses Pelagos at `/run/pelagos/cri.sock` instead of containerd. The agent DaemonSet mounts that socket and the attestor is configured to use it.

## Phases

### Phase 1 — SPIRE Server and Agent running (this experiment)
- Namespace, RBAC, ConfigMaps
- SPIRE Server as StatefulSet with NFS PVC
- SPIRE Agent as DaemonSet with k8s_psat node attestation
- Verify: `spire-server healthcheck` and `spire-agent healthcheck` both pass
- Verify: all three nodes show as attested in `spire-server agent list`

### Phase 2 — Workload identity (follow-on experiment)
- Register a demo workload entry
- Deploy a pod that fetches its SVID via the Workload API
- Verify the SVID contains the expected SPIFFE ID and is signed by the cluster CA

### Phase 3 — mTLS between workloads (follow-on experiment)
- Two services; each gets a SPIFFE ID
- Envoy or spiffe-helper sidecar handles cert rotation and presents the SVID for mTLS
- No secrets, no cert management — identity is purely attestation-derived

## Apply

```
kubectl apply -f experiments/11-spire/namespace.yaml
kubectl apply -f experiments/11-spire/server-config.yaml
kubectl apply -f experiments/11-spire/server-rbac.yaml
kubectl apply -f experiments/11-spire/server-statefulset.yaml
kubectl apply -f experiments/11-spire/agent-config.yaml
kubectl apply -f experiments/11-spire/agent-rbac.yaml
kubectl apply -f experiments/11-spire/agent-daemonset.yaml
```

Or as one line: `kubectl apply -f experiments/11-spire/`

## Verify

Check server health: `kubectl exec -n spire statefulset/spire-server -- /opt/spire/bin/spire-server healthcheck`

List attested nodes: `kubectl exec -n spire statefulset/spire-server -- /opt/spire/bin/spire-server agent list`

Check agent health on a node: `kubectl exec -n spire daemonset/spire-agent -- /opt/spire/bin/spire-agent healthcheck`

## Key configuration decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Node attestor | `k8s_psat` | No TPM, no cloud — PSAT is the standard for bare-metal k3s |
| Workload attestor | `k8s` | Maps PID → pod via CRI socket |
| CRI socket | `/run/pelagos/cri.sock` | This cluster runs Pelagos, not containerd |
| Trust domain | `ipc.local` | Matches cluster naming convention |
| CA storage | NFS PVC | Persistent across server restarts; only storage class available |
| Server port | 8081 | SPIRE default |
| Workload API socket | `/run/spire/sockets/agent.sock` | Mounted into workload pods via hostPath |
