# SPIRE Startup Post-Mortem (2026-07-19)

After nightly cluster shutdown (21:00) and restart (05:00), all SPIRE agents were in
CrashLoopBackOff at ~13:25 UTC when the cluster was uncordoned. Two separate problems.

## Problem 1: stale trust bundle in ConfigMap

### Symptom

All agents crashed within 30 seconds with:

```
level=error msg="Agent crashed" error="create attestation client: failed to dial
dns:///spire-server:8081: context deadline exceeded: connection error: desc =
\"transport: authentication handshake failed: x509svid: could not verify leaf
certificate: x509: certificate signed by unknown authority\""
```

### Root cause

The SPIRE server's `k8sbundle` Notifier plugin is responsible for keeping the
`spire-bundle` ConfigMap in sync with the server's active trust bundle. When the server
pod restarts, the Notifier pushes the current bundle to the ConfigMap on startup — but
only if the Kubernetes API is reachable at that moment.

At 05:00, nodes are powered on and k3s starts automatically. The SPIRE server StatefulSet
(which has a PVC for its SQLite data) comes up on ipc4 and the Notifier fires. However,
at that moment the cluster API server may not yet be fully accepting requests — the
Notifier call fails silently, and the stale bundle stays in the ConfigMap.

The server's CA had rotated since the bundle was last successfully pushed (the ConfigMap
had a CA from 2026-07-17 13:00–2026-07-18 13:01, expired). Agents loaded this stale
bundle and then failed the TLS handshake because the server's current leaf cert was
signed by a newer CA not in the bundle.

### Fix

Pull the current bundle from the server and patch the ConfigMap manually:

```
kubectl exec -n spire spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server bundle show > /tmp/spire-bundle.pem
kubectl create configmap -n spire spire-bundle \
  --from-file=bundle.crt=/tmp/spire-bundle.pem -o yaml --dry-run=client \
  | kubectl apply -f -
kubectl delete pods -n spire -l app=spire-agent
```

### Mitigation needed

The morning startup script (`scripts/cluster-scheduler/morning-on.sh`) now uncordons
nodes only after all 6 are Ready, which delays pod scheduling until the API server is
stable. This gives the k8sbundle Notifier a better chance of succeeding on server
startup. However, the server starts before pods are scheduled to run, so a race remains
if the server pod comes up before the API server is accepting writes.

A more robust fix would add a startup probe or init step that verifies the ConfigMap
contains a non-expired certificate before the server pod is considered ready. This is
tracked as a GitHub issue.

## Problem 2: ipc9 slow TPM attestation (~76 seconds)

### Symptom

After the bundle was fixed and agents restarted, five agents attested in 11–34 seconds.
The ipc9 agent consistently took ~76 seconds, appearing stuck between log lines:

```
level=info msg="SVID is not found. Starting node attestation"
... 76 seconds of silence ...
level=info msg="Node attestation was successful"
```

### Root cause: different TPM hardware

ipc9 has a **Nuvoton NPCT75x** firmware TPM, while ipc7 and ipc8 have **Infineon
SLB9** discrete chips:

| Node | Manufacturer | Chip | Type |
|------|-------------|------|------|
| ipc7 | `0x49465800` IFX | Infineon OPTIGA SLB9 | Discrete |
| ipc8 | `0x49465800` IFX | Infineon OPTIGA SLB9 | Discrete |
| ipc9 | `0x4E544300` NTC | Nuvoton NPCT75x | Firmware (fTPM) |

The Nuvoton NPCT75x is a firmware TPM — implemented in management controller firmware
rather than dedicated silicon. Its EK certificate is signed by a different CA chain
(`NuvotonTPMRootCA22111`) and is accessible at a different NVRAM layout than the
Infineon chips (20 indexes vs 15, additional vendor-specific handles).

Raw TPM operation speeds (hash, ECC keygen, RSA EK creation) are comparable between
ipc9 and the Infineon nodes. The 76-second delay therefore occurs at a higher level in
the attestation flow — likely a timeout in one specific operation, such as:

- The Go TPM library (`github.com/google/go-tpm`) attempting an operation that the
  Nuvoton fTPM handles differently, hitting an internal retry or timeout
- The `tpm_devid` plugin trying a specific NVRAM index or key handle that behaves
  differently on Nuvoton firmware vs Infineon hardware
- The Nuvoton firmware serializing concurrent TPM resource manager access differently

The exact call has not yet been isolated. See the GitHub issue for the active
investigation with bpftrace/strace.

### Current status

The liveness probe (`initialDelaySeconds: 15, periodSeconds: 60, failureThreshold: 3`)
allows up to ~135 seconds before killing the container. At 76 seconds, ipc9 attests
comfortably within this window and runs stably afterwards.

The 4371 restart count on the pre-2026-07-19 agent was caused by Problem 1 (stale
bundle preventing connection entirely), not by the 76-second delay. With the bundle now
properly maintained by a running Notifier, ipc9 is expected to be stable between
cluster restarts.

### Investigation needed

Trace the Go TPM library calls inside the running SPIRE agent on ipc9 to identify
which operation stalls. See the GitHub issue for the bpftrace/strace methodology.
