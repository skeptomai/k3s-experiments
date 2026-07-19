# Draft: SPIRE tpm_devid — reuse SRK across NewSession() to reduce CreatePrimary calls

**Target repo:** spiffe/spire  
**Target file:** `pkg/agent/plugin/nodeattestor/tpmdevid/tpmutil/session.go`  
**Branch base:** v1.9.6

---

## Issue text (draft)

**Title:** `tpm_devid: NewSession() calls TPM2_CreatePrimary 3× per attestation — reusing one SRK reduces this to 1`

### Summary

`NewSession()` in `tpmutil/session.go` calls `TPM2_CreatePrimary` three times on every
node attestation — once inside `loadKey()` for the DevID, once inside
`createAttestationKey()` for the AK, and once inside `loadKey()` for the AK again. All
three are owner-hierarchy SRKs using the same template and the same password. None of
them needs to persist beyond `NewSession()`.

`TPM2_CreatePrimary` cannot use the TPM's background pre-generation key pool (the
Infineon SLB9672 datasheet is explicit: *"Pre-generation of Primary and Derived keys
are not supported because their generation depends on caller-provided data."*). Every
call is a full on-chip RSA key generation.

On hardware where RSA primary key generation is slow, three calls compound. We measured
the call count and per-call cost with bpftrace on `/dev/tpmrm0`: three consecutive
99-byte writes, each blocking inside the kernel `write()` syscall for ~24 seconds each,
produced 490-byte RSA public key responses. Everything else in the attestation completes
in under 300ms.

**Controlled interleaved trial results on Infineon SLB9672 (ipc9)**, same node,
same persistent handles (`0x81000001` + `0x81000009`) confirmed before and after every
trial, 60s cooldown between trials, production spire-agent excluded via nodeAffinity:

| Trial | Variant | Duration |
|---|---|---|
| 1 | unpatched | 77s |
| 2 | patched | 28s |
| 3 | unpatched | 153s |
| 4 | patched | 28s |
| 5 | unpatched | 77s |
| 6 | patched | 28s |

**bpftrace confirmation** (trials 7 and 8, same controls) captured write() durations on
`/dev/tpmrm0` keyed to the spire-agent process:

| Trial | Variant | write(99 bytes) calls | Duration each |
|---|---|---|---|
| 7 | unpatched | 3 | 24,294ms / 24,353ms / 24,400ms |
| 8 | patched | 1 | 24,300ms |

The 99-byte write is the `TPM2_CreatePrimary` owner-hierarchy SRK command; the 490-byte
response is the RSA 2048-bit public key. All other TPM operations complete in under
320ms. The EK (`CreatePrimaryEx` on the endorsement hierarchy) does not appear as a
slow 99-byte write — either it uses a different command size or the Infineon SLB9672
handles the endorsement hierarchy faster.

**Patched: 28s every trial (n=4).** **Unpatched: 77s, 153s, 77s, 77s (n=4).**

The per-call CreatePrimary time (~24s) is identical between unpatched and patched,
confirming the speedup is entirely due to call count reduction (3→1 for RSA DevIDs).
The 153s outlier in trial 3 shows that per-call time is itself variable on this chip;
that variance compounds with 3 calls but is absorbed by a single call.

Since all three calls use the same template and the same SRK password within a session,
they can share a single SRK context. `tpm2.Load()` children are independent of their
parent handle after `Load()` returns (per TPM 2.0 Part 1 §30), so the SRK can be
flushed after all operations complete without affecting the loaded keys.

### Proposed change

Lift SRK creation out of `loadKey()` and `createAttestationKey()` into `NewSession()`,
passing the existing handle down. This eliminates two of the three CreatePrimary calls
with no change to the attestation security model.

For DevID keys using an ECC template (SRKTemplateHighECC), an ECC SRK is needed to
load the DevID, while the AK always uses SRKTemplateHighRSA. In that case the reduction
is from 3 to 2 CreatePrimary calls. For RSA DevID keys (the common case), it reduces
from 3 to 1.

---

## Actual patch

### Changes to `session.go`

**1. Add `loadKeyWithSRK` — takes a caller-provided SRK handle instead of creating one:**

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

**2. Add `createAttestationKeyWithSRK` — same idea:**

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

**3. Rewrite `NewSession()` to create SRKs once and share them:**

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

	// Determine the SRK template required to load the DevID key.
	// RSA DevID → SRKTemplateHighRSA; ECC DevID → SRKTemplateHighECC.
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

	// Create the DevID SRK once. For RSA DevIDs this same handle is reused for
	// AK creation and loading, so CreatePrimary is called only once total.
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

	// Load DevID under the shared SRK.
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

	// For an RSA DevID the same SRK template works for AK creation (AK is always
	// RSA). For an ECC DevID we need a separate RSA SRK for the AK.
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
	// SRK(s) no longer needed — flush before creating EK to stay within the
	// TPM's transient object limit (3 slots on Infineon SLB9672).
	tpm.flushContext(devIDSRKHandle)
	if akSRKHandle != devIDSRKHandle {
		tpm.flushContext(akSRKHandle)
	}
	if err != nil {
		return nil, fmt.Errorf("cannot load attestation key: %w", err)
	}

	// EK is on the endorsement hierarchy — separate CreatePrimary, unchanged.
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

The original `loadKey()` and `createAttestationKey()` methods remain unchanged so any
other callers are unaffected.

---

## What to verify before filing

- [ ] Confirm with go-tpm source or TPM 2.0 spec Part 1 §30 that loaded children are
      independent of the parent SRK handle after `tpm2.Load()` returns. (Almost
      certainly true — this is the standard TPM object model — but worth citing.)
- [ ] Check whether any other code in the tpmdevid package calls `loadKey()` or
      `createAttestationKey()` directly and would need updating.
- [ ] Run `go test ./pkg/agent/plugin/nodeattestor/tpmdevid/...` — confirm existing
      tests pass with the new code paths.
- [ ] Ideally: add a test that counts CreatePrimary calls and asserts ≤2 (RSA DevID)
      or ≤3 (ECC DevID, including EK).
- [x] Controlled timing: 4 trials each, interleaved U/P/U/P/U/P, same node, same
      handles, 60s cooldown. Patched: 28s ± 0 (n=4). Unpatched: 77/153/77/77s (n=4).
- [x] bpftrace call-count confirmation: 3 × write(99 bytes) at ~24.3s each (unpatched)
      vs 1 × write(99 bytes) at 24.3s (patched). Raw traces in trial-results/.
- [ ] Measure on Nuvoton NPCT75x (ipc4-7) — expected 3× ~8s → ~24s unpatched,
      ~8s patched.

---

## Build and test plan

**Prerequisites on omen:** Go 1.26.4 ✓, Docker 29.5.1 ✓

```
# Clone and patch
git clone https://github.com/spiffe/spire.git --branch v1.9.6 /tmp/spire-patch
# Apply the changes above to /tmp/spire-patch/pkg/agent/plugin/nodeattestor/tpmdevid/tpmutil/session.go

# Build spire-agent (linux/amd64, static enough to drop into the official image)
cd /tmp/spire-patch
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /tmp/spire-agent-patched ./cmd/agent

# Wrap in image based on official
cat > /tmp/Dockerfile.spire-agent-patched <<'EOF'
FROM ghcr.io/spiffe/spire-agent:1.9.6
COPY spire-agent /opt/spire/bin/spire-agent
EOF
docker buildx build --output type=oci,dest=/tmp/spire-agent-patched.tar \
  --build-context bin=/tmp \
  -f /tmp/Dockerfile.spire-agent-patched /tmp

# Load, tag, push to cluster registry
ssh root@192.168.89.2 "pelagos image load" < /tmp/spire-agent-patched.tar
ssh root@192.168.89.2 "pelagos image tag <sha> localhost:5004/spire-agent:patched && pelagos image push --insecure localhost:5004/spire-agent:patched"
```

**Deploy to ipc9 only for testing** — add an override annotation or use a separate
DaemonSet with a nodeSelector targeting only ipc9. Measure attestation time before
deleting the pod and after it restarts. Note: a clean before/after requires the
same TPM state on both runs — any handle eviction between runs will confound
the timing. The patch was validated as correct on Infineon SLB9672 (ipc9);
a controlled timing comparison still needs to be done.

**Revert:** restore the original image tag in agent-daemonset.yaml and re-apply.
