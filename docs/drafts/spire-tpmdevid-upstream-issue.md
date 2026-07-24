# Upstream issue text — ready to file when approved

**Repo:** spiffe/spire  
**File:** `pkg/agent/plugin/nodeattestor/tpmdevid/tpmutil/session.go`  
**Branch:** v1.9.6 (also present on main)

---

## Title

`tpm_devid: NewSession() calls TPM2_CreatePrimary 3× per attestation — reusing one SRK reduces this to 1`

---

## Body

### Summary

`NewSession()` in `tpmutil/session.go` calls `TPM2_CreatePrimary` three times on every
node attestation:

1. Inside `loadKey()` for the DevID key
2. Inside `createAttestationKey()` for the attestation key
3. Inside `loadKey()` for the attestation key

All three use the owner hierarchy with the same SRK template and the same password.
None of the resulting handles needs to persist beyond `NewSession()`. They can share
a single SRK context.

### Why this matters

`TPM2_CreatePrimary` performs a full on-chip RSA 2048-bit key derivation on every call.
It cannot use the TPM's background pre-generation pool — the Infineon SLB9672 datasheet
is explicit: *"Pre-generation of Primary and Derived keys are not supported because their
generation depends on caller-provided data."* Other TPM vendors have the same constraint.

On hardware where this operation is slow, three calls compound significantly. We traced
the attestation path with bpftrace on `/dev/tpmrm0`, watching `write()`/`read()` call
durations from the `spire-agent` process:

**Unpatched (v1.9.6) — Infineon SLB9672:**

```
write(99 bytes) → write done in 24,294 ms → read() returned 490 bytes
write(99 bytes) → write done in 24,353 ms → read() returned 490 bytes
write(99 bytes) → write done in 24,400 ms → read() returned 490 bytes
```

A 99-byte write returning a 490-byte RSA public key is `TPM2_CreatePrimary`. Three of
them, back to back. Everything else in the attestation — key loads, `ActivateCredential`,
the SPIRE protocol round-trip — completes in under 320ms total.

**Patched — same hardware, same session:**

```
write(99 bytes) → write done in 24,300 ms → read() returned 490 bytes
```

One call. The per-call time is identical; the reduction is entirely from call count.

**Interleaved timing results**, 4 trials per variant, same node, same TPM state,
60-second cooldown between trials:

| Variant | Trial durations |
|---|---|
| Unpatched | 77s, 153s, 77s, 77s |
| Patched | 28s, 28s, 28s, 28s |

The 153s outlier shows that per-call `CreatePrimary` time is variable on this chip.
With 3 calls, any slow call compounds; with 1 call, variance is absorbed once.

The endorsement-hierarchy `CreatePrimary` (for the EK) is unaffected — it does not
appear as a slow call on this hardware and is unchanged by this patch.

### Root cause in code

`loadKey()` creates an SRK, loads a child key, and defers the SRK flush:

```go
func (c *Session) loadKey(pubKey, privKey []byte, ...) (*SigningKey, error) {
    srkHandle, ..., err := tpm2.CreatePrimaryEx(c.rwc, tpm2.HandleOwner, ...)
    defer c.flushContext(srkHandle)
    ...
    keyHandle, _, err := tpm2.Load(c.rwc, srkHandle, ...)
    ...
}
```

`createAttestationKey()` does the same. `NewSession()` calls these three times
in sequence, creating a new SRK each time rather than reusing the one from the
previous call.

Per TPM 2.0 Part 1 §30, a loaded child object (`tpm2.Load()`) is independent of its
parent handle after loading completes. The parent SRK can be flushed without affecting
the child. There is no correctness reason to create a new SRK for each operation.

### Proposed fix

Add `loadKeyWithSRK` and `createAttestationKeyWithSRK` helpers that accept a
caller-provided SRK handle. Rewrite `NewSession()` to create one SRK and pass it
to all three operations. The original `loadKey()` and `createAttestationKey()` are
preserved unchanged for any other callers.

One subtlety: the SRK must be flushed explicitly before creating the EK, not deferred
to function return. At the point of EK creation, the transient object table holds the
SRK + loaded DevID + loaded AK. On chips with 3 transient slots (Infineon SLB9672),
a deferred flush causes `TPM_RC_OBJECT_MEMORY` on the EK `CreatePrimary`. Flushing
the SRK eagerly after the AK is loaded brings the count to 2 (DevID + AK), leaving
room for the EK.

For RSA DevIDs (the common case): 3 `CreatePrimary` calls → 1.
For ECC DevIDs: the AK always uses `SRKTemplateHighRSA`, so a second SRK is still
needed; 3 `CreatePrimary` calls → 2.

### Patch

**New helper `loadKeyWithSRK`:**

```go
// loadKeyWithSRK loads a key pair into the TPM under an already-created SRK.
// The caller is responsible for flushing srkHandle after all operations complete.
func (c *Session) loadKeyWithSRK(
	pubKey, privKey []byte,
	srkHandle tpmutil.Handle,
	parentKeyPassword, keyPassword string,
) (*SigningKey, error) {
	pub, err := tpm2.DecodePublic(pubKey)
	if err != nil {
		return nil, fmt.Errorf("tpm2.DecodePublic failed: %w", err)
	}

	canSign := pub.Attributes&tpm2.FlagSign != 0
	if !canSign {
		return nil, errors.New("not a signing key")
	}

	var sigHashAlg tpm2.Algorithm
	switch pub.Type {
	case tpm2.AlgRSA:
		rsaParams := pub.RSAParameters
		if rsaParams != nil {
			sigHashAlg = rsaParams.Sign.Hash
		}
	case tpm2.AlgECC:
		eccParams := pub.ECCParameters
		if eccParams != nil {
			sigHashAlg = eccParams.Sign.Hash
		}
	default:
		return nil, fmt.Errorf("bad key type: 0x%04x", pub.Type)
	}

	if sigHashAlg.IsNull() {
		return nil, errors.New("signature hash algorithm is NULL")
	}

	keyHandle, _, err := tpm2.Load(c.rwc, srkHandle, parentKeyPassword, pubKey, privKey)
	if err != nil {
		return nil, fmt.Errorf("tpm2.Load failed: %w", err)
	}

	return &SigningKey{
		Handle:     keyHandle,
		sigHashAlg: sigHashAlg,
		rw:         c.rwc,
		log:        c.log,
		password:   keyPassword,
	}, nil
}
```

**New helper `createAttestationKeyWithSRK`:**

```go
// createAttestationKeyWithSRK creates an RSA attestation key under an existing SRK.
// The caller is responsible for flushing srkHandle after all operations complete.
func (c *Session) createAttestationKeyWithSRK(
	srkHandle tpmutil.Handle,
	parentKeyPassword, keyPassword string,
) ([]byte, []byte, error) {
	privBlob, pubBlob, _, _, _, err := tpm2.CreateKey(
		c.rwc,
		srkHandle,
		tpm2.PCRSelection{},
		parentKeyPassword,
		keyPassword,
		client.AKTemplateRSA(),
	)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create AK: %w", err)
	}
	return privBlob, pubBlob, nil
}
```

**Rewritten `NewSession()`:**

```go
func NewSession(scfg *SessionConfig) (*Session, error) {
	if scfg.Log == nil {
		return nil, errors.New("missing logger")
	}

	rwc, err := OpenTPM(scfg.DevicePath)
	if err != nil {
		return nil, fmt.Errorf("cannot open TPM at %q: %w", scfg.DevicePath, err)
	}

	tpm := &Session{
		rwc:                          rwc,
		log:                          scfg.Log,
		endorsementHierarchyPassword: scfg.Passwords.EndorsementHierarchy,
		ownerHierarchyPassword:       scfg.Passwords.OwnerHierarchy,
	}

	defer func() {
		if err != nil {
			tpm.Close()
		}
	}()

	srkPassword, err := newRandomPassword()
	if err != nil {
		return nil, fmt.Errorf("cannot generate random password for storage root key: %w", err)
	}

	// Determine SRK template from the DevID key type.
	devIDPubDecoded, err := tpm2.DecodePublic(scfg.DevIDPub)
	if err != nil {
		return nil, fmt.Errorf("cannot decode DevID public key: %w", err)
	}
	var devIDSRKTemplate tpm2.Public
	switch devIDPubDecoded.Type {
	case tpm2.AlgRSA:
		devIDSRKTemplate = SRKTemplateHighRSA()
	case tpm2.AlgECC:
		devIDSRKTemplate = SRKTemplateHighECC()
	default:
		return nil, fmt.Errorf("unsupported DevID key type: 0x%04x", devIDPubDecoded.Type)
	}

	// Create one owner-hierarchy SRK. For RSA DevIDs it is reused for both
	// DevID loading and AK creation/loading, so CreatePrimary is called once.
	devIDSRKHandle, _, _, _, _, _, err := tpm2.CreatePrimaryEx(
		rwc, tpm2.HandleOwner,
		tpm2.PCRSelection{},
		scfg.Passwords.OwnerHierarchy,
		srkPassword,
		devIDSRKTemplate,
	)
	if err != nil {
		return nil, fmt.Errorf("cannot create owner SRK: %w", err)
	}

	tpm.devID, err = tpm.loadKeyWithSRK(
		scfg.DevIDPub, scfg.DevIDPriv,
		devIDSRKHandle,
		srkPassword, scfg.Passwords.DevIDKey,
	)
	if err != nil {
		tpm.flushContext(devIDSRKHandle)
		return nil, fmt.Errorf("cannot load DevID key on TPM: %w", err)
	}

	akPassword, err := newRandomPassword()
	if err != nil {
		tpm.flushContext(devIDSRKHandle)
		return nil, fmt.Errorf("cannot generate random password for attestation key: %w", err)
	}

	// For ECC DevIDs the AK requires a separate RSA SRK; for RSA DevIDs reuse the same.
	akSRKHandle := devIDSRKHandle
	if devIDPubDecoded.Type == tpm2.AlgECC {
		akSRKHandle, _, _, _, _, _, err = tpm2.CreatePrimaryEx(
			rwc, tpm2.HandleOwner,
			tpm2.PCRSelection{},
			scfg.Passwords.OwnerHierarchy,
			srkPassword,
			SRKTemplateHighRSA(),
		)
		if err != nil {
			tpm.flushContext(devIDSRKHandle)
			return nil, fmt.Errorf("cannot create RSA SRK for attestation key: %w", err)
		}
	}

	akPriv, akPub, err := tpm.createAttestationKeyWithSRK(akSRKHandle, srkPassword, akPassword)
	if err != nil {
		tpm.flushContext(devIDSRKHandle)
		if akSRKHandle != devIDSRKHandle {
			tpm.flushContext(akSRKHandle)
		}
		return nil, fmt.Errorf("cannot create attestation key: %w", err)
	}
	tpm.akPub = akPub

	tpm.ak, err = tpm.loadKeyWithSRK(
		akPub, akPriv,
		akSRKHandle,
		srkPassword, akPassword,
	)
	// Flush SRK(s) before creating the EK: at this point devID and ak are loaded
	// (2 transient slots). Some chips enforce a 3-slot limit; the EK CreatePrimary
	// needs the third slot, so we flush eagerly rather than deferring to return.
	tpm.flushContext(devIDSRKHandle)
	if akSRKHandle != devIDSRKHandle {
		tpm.flushContext(akSRKHandle)
	}
	if err != nil {
		return nil, fmt.Errorf("cannot load attestation key: %w", err)
	}

	// EK is on the endorsement hierarchy — unchanged.
	tpm.ekHandle, tpm.ekPub, _, _, _, _, err =
		tpm2.CreatePrimaryEx(rwc, tpm2.HandleEndorsement,
			tpm2.PCRSelection{},
			scfg.Passwords.EndorsementHierarchy,
			"",
			client.DefaultEKTemplateRSA())
	if err != nil {
		return nil, fmt.Errorf("cannot create endorsement key: %w", err)
	}

	return tpm, nil
}
```

### Not yet verified

- Existing unit tests passing with the new code paths (`go test ./pkg/agent/plugin/nodeattestor/tpmdevid/...`) — happy to run these if a maintainer points to a TPM simulator setup.
- Behaviour on ECC DevID keys — the code path is correct by inspection but has not been exercised on real hardware.
- Timing on Nuvoton NPCT75x — the structural fix (3→1 calls) applies regardless of hardware; measured only on Infineon SLB9672.
