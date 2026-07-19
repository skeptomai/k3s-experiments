# TPM Hardware

## Node TPM map (confirmed 2026-07-19)

| Node | Manufacturer | Chip | Firmware |
|------|-------------|------|----------|
| ipc4-7 | `0x4E544300` NTC | Nuvoton NPCT75x | 7.0.2 |
| ipc8 | `0x49465800` IFX | Infineon SLB9672 | 15.0.22 |
| ipc9 | `0x49465800` IFX | Infineon SLB9672 | 15.0.22 |

HP Elite Mini 800 G9 (ipc4-6) ships with either Infineon SLB9672 or Nuvoton NPCT75x
by production lot. ipc7-9 are Intel Core i5-12500 (non-T) machines; ipc7 got Nuvoton,
ipc8/ipc9 got Infineon.

To query: `sudo tpm2_getcap properties-fixed | grep -A2 TPMManufacturer`

## ipc9 slow SPIRE attestation (investigated 2026-07-19)

Baseline attestation time on ipc9: **~77s**. ipc8 (same chip, same firmware): ~34s.
ipc4-7 (Nuvoton): ~23s.

bpftrace on `/dev/tpmrm0` during SPIRE agent restart identified the cause: `tpm_devid`
`NewSession()` calls `TPM2_CreatePrimary` **3 times**, each blocking for ~24s while the
Infineon chip generates an RSA 2048-bit SRK on-chip. All other TPM operations complete
in under 300ms. The Infineon datasheet confirms `CreatePrimary` cannot use the
background pre-generation pool (caller-provided data required). Why ipc9 is slower than
ipc8 at the same operation is unknown.

See `docs/spire-startup-postmortem.md` for the full investigation.

### ipc9 mystery persistent handle (evicted 2026-07-19)

ipc9 had persistent handle `0x81000002`: RSA 2048, `restricted|sign`, authorization
policy set — an AIK-pattern key of unknown origin. It was evicted. Current expected
handles on all nodes:

| Handle | Purpose | Created by |
|--------|---------|-----------|
| `0x81000001` | SRK (owner hierarchy) | `provision-tpm-devid.sh` |
| `0x81000009` | DevID signing key | `provision-tpm-devid.sh` |

`provision-tpm-devid.sh` does not create anything at `0x81000002`, so it will not
return on reinstall. Eviction did not change per-call `CreatePrimary` time on ipc9.

To check handles: `sudo tpm2_getcap handles-persistent`

## SPIRE tpm_devid SRK-reuse patch (in progress)

`tpm_devid` `NewSession()` creates a fresh owner-hierarchy SRK for each of three
operations (load DevID, create AK, load AK) using the same template and password.
These can share one SRK handle, reducing `CreatePrimary` calls from 3× to 1× for RSA
DevIDs.

- **Draft upstream issue + patch:** `docs/drafts/spire-tpmdevid-persist-srk.md`
- **Cluster build + test pipeline:** `experiments/28-spire-tpmdevid-patch/`
- **Status:** patch attests correctly on ipc9; observed 77s (unpatched) → 28s (patched),
  consistent with 3×→1× at ~24s/call, but not a controlled measurement
- **Not yet filed** — needs a controlled multi-run timing comparison first

### Implementation note: eager SRK flush required

The SRK must be flushed explicitly after all child keys are loaded, before creating the
EK. The Infineon SLB9672 has **3 transient object slots**. With a deferred flush: SRK +
devID + AK = 3 slots occupied when EK `CreatePrimary` is attempted → slot exhaustion.
Flush the SRK as soon as `tpm.ak` is loaded and the SRK is no longer needed.
