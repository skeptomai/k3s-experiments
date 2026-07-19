# Draft: SPIRE tpm_devid — persist SRK to avoid CreatePrimary on every attestation

**Target repo:** spiffe/spire
**File:** `pkg/agent/plugin/nodeattestor/tpmdevid/tpmutil/session.go`

---

## Issue text (draft)

**Title:** `tpm_devid: NewSession() calls TPM2_CreatePrimary 3× per attestation; persisting SRK would eliminate most of the cost`

### Summary

`NewSession()` in `tpmutil/session.go` creates three transient Storage Root Keys (SRKs)
via `TPM2_CreatePrimary` on every node attestation, then flushes each one after use.
`TPM2_CreatePrimary` requires a full on-chip RSA key generation every time — TPMs
explicitly cannot use background pre-generated key pools for primary keys (confirmed in
the Infineon SLB9672 datasheet: "Pre-generation of Primary and Derived keys are not
supported because their generation depends on caller-provided data").

On hardware where RSA key generation is slow, this compounds:

| Node | TPM | Per-CreatePrimary | Total attestation |
|------|-----|------------------|-------------------|
| ipc7 | Nuvoton NPCT75x | ~7–8s | ~23s |
| ipc8 | Infineon SLB9672 | ~10s | ~34s |
| ipc9 | Infineon SLB9672 | ~24s | ~76s |

The delay is confirmed inside the kernel `write()` syscall — the hardware itself takes
that long to respond. All other TPM operations in the attestation complete in under 300ms.
Eliminating the three `CreatePrimary` calls is the only meaningful way to reduce
attestation time.

### Evidence

bpftrace on ipc9 watching `/dev/tpmrm0` during agent restart captured three consecutive
`write(99 bytes)` calls that each blocked for ~24.2 seconds before returning a 490-byte
RSA public key response:

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

3 × 24.2s = 72.6s of the 76s attestation time.

Infineon SLB9672 datasheet (FW15.xx, p. XX):
> "Pre-generation is only supported for (RSA 2k) Ordinary keys. Pre-generation of
> Primary and Derived keys are not supported because their generation depends on
> caller-provided data."

### Proposed fix

**Option A (minimal, no persistent state change): reuse one transient SRK**

`NewSession()` currently creates three separate SRK contexts — one for loading the
DevID key, one for creating the AK, and one for loading the AK. All three use the same
`SRKTemplateHighRSA()` template. The three are independent only because each is flushed
after the key operation that used it, but there is no reason they cannot share a single
SRK context:

```go
// Instead of:
srk1, _ := tpm2.CreatePrimaryEx(rw, tpm2.HandleOwner, ..., SRKTemplateHighRSA())
devIDKey, _ := tpm2.Load(rw, srk1, ...)
tpm2.FlushContext(rw, srk1)

srk2, _ := tpm2.CreatePrimaryEx(rw, tpm2.HandleOwner, ..., SRKTemplateHighRSA())
akPriv, akPub, _ := tpm2.CreateKey(rw, srk2, ..., AKTemplateRSA())
tpm2.FlushContext(rw, srk2)

srk3, _ := tpm2.CreatePrimaryEx(rw, tpm2.HandleOwner, ..., SRKTemplateHighRSA())
ak, _ := tpm2.Load(rw, srk3, akPriv, akPub)
tpm2.FlushContext(rw, srk3)

// Do instead (one CreatePrimary, reuse the same srk):
srk, _ := tpm2.CreatePrimaryEx(rw, tpm2.HandleOwner, ..., SRKTemplateHighRSA())
defer tpm2.FlushContext(rw, srk)

devIDKey, _ := tpm2.Load(rw, srk, ...)
akPriv, akPub, _ := tpm2.CreateKey(rw, srk, ..., AKTemplateRSA())
ak, _ := tpm2.Load(rw, srk, akPriv, akPub)
```

This requires no persistent state changes, no new configuration, and no NV handle
management. It reduces `CreatePrimary` from 3 calls to 1 per attestation.

**Option B (larger change): persist the SRK across sessions**

On first attestation, create the SRK and persist it via `TPM2_EvictControl` to a stable
handle (needs a configurable handle to avoid conflicting with OS tooling at 0x81000001).
On subsequent attestations, use `tpm2.LoadExternal` or load from the handle directly.
This reduces CreatePrimary to 0 calls after the first run. Requires:
- A plugin config option for the persistent SRK handle
- Handling the case where the handle doesn't exist (first run, or after TPM clear)
- Coordination with the provisioning script so the handle is pre-populated

Option A is a safe, low-risk improvement achievable in the same PR. Option B can follow
as a separate enhancement.

### Impact

- Reduces attestation time for all tpm_devid users on any hardware where RSA primary
  key generation is measurably slow (all Infineon discrete TPMs, Nuvoton fTPMs, and
  any TPM where RSA generation takes >1s)
- No behavioral change to the attestation security model — the SRK is used only as a
  parent for transient operations; its identity is not part of the trust proof
- No configuration changes required for Option A
- Backward compatible

### References

- Infineon OPTIGA TPM SLB9672 FW15.xx Datasheet — pre-generation pool section
- wolfTPM benchmarks: SLB9672 RSA 2048 keygen avg 1,568ms (ordinary key, uses pool);
  CreatePrimary cannot use pool and takes 8–24s depending on chip lot
- Infineon developer community thread on varied CreatePrimary timing across same-model chips

---

## Patch sketch (Option A)

The change is in `pkg/agent/plugin/nodeattestor/tpmdevid/tpmutil/session.go`.

The current pattern (simplified from source):

```go
func NewSession(rwc io.ReadWriteCloser, ...) (*Session, error) {
    // Load DevID under SRK 1
    srkHandle1, _, err := tpm2.CreatePrimaryEx(rwc, tpm2.HandleOwner, ..., SRKTemplate)
    devIDHandle, _, err := tpm2.Load(rwc, srkHandle1, devIDPriv, devIDPub)
    if err := tpm2.FlushContext(rwc, srkHandle1); err != nil { ... }

    // Create AK under SRK 2
    srkHandle2, _, err := tpm2.CreatePrimaryEx(rwc, tpm2.HandleOwner, ..., SRKTemplate)
    akPriv, akPub, _, _, _, err := tpm2.CreateKey(rwc, srkHandle2, ..., AKTemplate)
    if err := tpm2.FlushContext(rwc, srkHandle2); err != nil { ... }

    // Load AK under SRK 3
    srkHandle3, _, err := tpm2.CreatePrimaryEx(rwc, tpm2.HandleOwner, ..., SRKTemplate)
    akHandle, _, err := tpm2.Load(rwc, srkHandle3, akPriv, akPub)
    if err := tpm2.FlushContext(rwc, srkHandle3); err != nil { ... }

    // Create EK (on endorsement hierarchy — separate, keep as-is)
    ekHandle, _, err := tpm2.CreatePrimaryEx(rwc, tpm2.HandleEndorsement, ..., EKTemplate)
    ...
}
```

Proposed change — create a single SRK and reuse it:

```go
func NewSession(rwc io.ReadWriteCloser, ...) (*Session, error) {
    // Single SRK for all owner-hierarchy operations
    srkHandle, _, err := tpm2.CreatePrimaryEx(rwc, tpm2.HandleOwner, ..., SRKTemplate)
    if err != nil {
        return nil, fmt.Errorf("creating SRK: %w", err)
    }
    defer func() {
        // Flush SRK once all transient children are loaded; loaded children
        // are independent of the parent handle after Load() returns.
        tpm2.FlushContext(rwc, srkHandle)
    }()

    // Load DevID under the shared SRK
    devIDHandle, _, err := tpm2.Load(rwc, srkHandle, devIDPriv, devIDPub)
    if err != nil { ... }

    // Create AK under the shared SRK
    akPriv, akPub, _, _, _, err := tpm2.CreateKey(rwc, srkHandle, ..., AKTemplate)
    if err != nil { ... }

    // Load AK under the shared SRK
    akHandle, _, err := tpm2.Load(rwc, srkHandle, akPriv, akPub)
    if err != nil { ... }

    // EK is on the endorsement hierarchy — unchanged
    ekHandle, _, err := tpm2.CreatePrimaryEx(rwc, tpm2.HandleEndorsement, ..., EKTemplate)
    ...
}
```

Key correctness note: `tpm2.Load()` returns a handle that is independent of the parent
SRK handle after the call returns. The loaded key lives in the TPM's transient object
memory under its own handle. Flushing the SRK after all Load() calls does not invalidate
the loaded children. This is standard TPM2 behavior.

The EK CreatePrimary (on `HandleEndorsement`, not `HandleOwner`) is left unchanged —
it uses a different hierarchy and a different template, and must remain separate.

---

## Before submitting

- [ ] Verify that tpm2.Load() children are truly independent of parent after Load()
      returns (check go-tpm source or TPM2 spec Part 1 §30)
- [ ] Confirm the SRK template used for devID load and AK create/load is identical
      (if different templates are needed for different operations, shared SRK may not work)
- [ ] Run SPIRE's tpm_devid integration tests with the change
- [ ] Benchmark attestation time before/after on at least two chip types
- [ ] Check if the go-tpm-tools library already provides a helper that does this pattern
