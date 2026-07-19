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

### TPM hardware map (corrected)

The cluster has two different TPM vendors across the six nodes:

| Node | Manufacturer | Chip | Type | Attestation time |
|------|-------------|------|------|-----------------|
| ipc4 | `0x4E544300` NTC | Nuvoton NPCT75x | Firmware (fTPM) | ~23s |
| ipc5 | `0x4E544300` NTC | Nuvoton NPCT75x | Firmware (fTPM) | ~23s |
| ipc6 | `0x4E544300` NTC | Nuvoton NPCT75x | Firmware (fTPM) | ~23s |
| ipc7 | `0x4E544300` NTC | Nuvoton NPCT75x | Firmware (fTPM) | ~23s |
| ipc8 | `0x49465800` IFX | Infineon SLB9672 | Discrete | ~34s |
| ipc9 | `0x49465800` IFX | Infineon SLB9672 | Discrete | ~76s |

The HP Elite Mini 800 G9 (ipc4-6) ships with either Infineon SLB9672 or Nuvoton
NPCT760HABYX depending on production lot. ipc7-9 are the Intel Core i5-12500 (non-T)
machines; ipc7 received a Nuvoton chip, ipc8 and ipc9 received Infineon.

### Root cause: TPM2_CreatePrimary takes 24 seconds on ipc9's chip

Traced with bpftrace on ipc9 during a SPIRE agent pod restart. The trace watched
`write()`/`read()` syscalls on `/dev/tpmrm0` from the `spire-agent` process and timed
each one.

The entire 76-second delay comes from three `write()` calls, each 99 bytes, each
blocking inside the kernel `write()` syscall for ~24.2 seconds:

```
write(99 bytes) -> TPM command sent
write done in 24171 ms
read() returned 490 bytes in 0 ms

write(99 bytes) -> TPM command sent
write done in 24250 ms
read() returned 490 bytes in 0 ms

write(99 bytes) -> TPM command sent
write done in 24266 ms
read() returned 490 bytes in 0 ms
```

A 99-byte command returning a 490-byte response is `TPM2_CreatePrimary` generating an
RSA 2048-bit Storage Root Key (SRK). SPIRE's tpm_devid plugin calls `CreatePrimary`
three times per attestation (to load the DevID key, create the attestation key, and
load the attestation key into separate transient SRK contexts).

3 × 24.2s = 72.6 seconds. The remaining ~3.4 seconds are all other TPM operations
(key loads, flushes, the ActivateCredential challenge) which complete in milliseconds.

The blocking happens inside the kernel `write()` — the TPM hardware on ipc9 takes
24 seconds to generate/return an RSA 2048-bit SRK. This is hardware behavior, not a
software timeout or retry loop.

### Why ipc8 is faster despite same model and firmware

ipc8 also has an Infineon SLB9672 with the same firmware version (`0xF0016`) and
attests in ~34s, implying its `CreatePrimary` takes ~10s per call rather than ~24s.
Both are the same chip model. The difference is likely one of:

- Different silicon production lots with different RSA key generation performance
- ipc9's chip is in a partially degraded state (NV storage wear, etc.)
- Some prior provisioning put ipc9's TPM in a state that makes RSA operations slower
  (ipc9 has an extra persistent handle at `0x81000002` — an RSA signing key with an
  authorization policy — that ipc8 does not have)

The extra handle `0x81000002` on ipc9 is worth investigating: it has
`fixedtpm|fixedparent|restricted|sign` attributes and an authorization policy, and was
not placed there by `provision-tpm-devid.sh`. Its origin is unknown.

### Current status

The liveness probe (`initialDelaySeconds: 15, periodSeconds: 60, failureThreshold: 3`)
allows up to ~135 seconds before killing the container. At 76 seconds, ipc9 attests
comfortably within this window and runs stably afterwards.

### Investigation needed

1. Identify the origin of persistent handle `0x81000002` on ipc9.
2. Test whether evicting that handle reduces `CreatePrimary` time on ipc9.
3. Run the same bpftrace on ipc8 to confirm its `CreatePrimary` time is ~10s.
4. Consider whether pre-provisioning a persistent SRK at a fixed handle would let
   SPIRE skip the three transient CreatePrimary calls entirely.
