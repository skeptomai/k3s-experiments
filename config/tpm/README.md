# config/tpm/

Public PKI material for SPIRE TPM DevID node attestation.

## Files

### `devid-ca.pem`
Self-signed CA certificate (EC P-256, 20-year validity) used to sign DevID certificates
for all cluster nodes. This is the `devid_ca_path` for the SPIRE server's `tpm_devid`
node attestor configuration.

The corresponding **private key is NOT in this repo** — it is stored in 1Password as
`ipc-cluster DevID CA key` (Private vault, notes field). The provisioning script
(`scripts/provision-tpm-devid.sh`) retrieves it via `op` at signing time.

### `endorsement-ca-bundle.pem`
Bundle of all manufacturer TPM EK CA certificates for the six cluster nodes. This is
the `endorsement_ca_path` for the SPIRE server's `tpm_devid` node attestor. Contains:

| Certificate | Covers | Chain level | Expiry |
|-------------|--------|-------------|--------|
| NPCTxxx ECC521 RootCA | ipc4, ipc5 (root) | Root | 2053 |
| NPCTxxx ECC384 LeafCA 022111 | ipc4, ipc5 (intermediate) | Intermediate | 2053 |
| NuvotonTPMRootCA2210 | ipc6 | Root (self-signed) | 2052 |
| NuvotonTPMRootCA2211 | ipc7 | Root (self-signed) | 2052 |
| Infineon OPTIGA(TM) RSA Root CA 2 | ipc8, ipc9 (root) | Root | 2054 |
| Infineon OPTIGA(TM) TPM 2.0 RSA CA 061 | ipc8, ipc9 (intermediate) | Intermediate | 2042 |

All certs were fetched from the CA Issuers AIA extensions of the node EK certificates
and verified as correct chain members before bundling.

**Note:** ipc8/9 EK certs expire 2037 (Infineon's shorter validity window). After that,
EK chain validation can be replaced with EK public key fingerprint enrollment — see
`docs/spire-concepts.md` for details.

## What is NOT Here

- `devid-ca.key.pem` — stored in 1Password, never committed
- Per-node DevID certificates and key blobs — live on nodes at `/etc/spire/`, generated
  by `scripts/provision-tpm-devid.sh` during provisioning/reinstall

## Regenerating the DevID CA

If the DevID CA needs to be replaced (compromise, expiry):

1. Generate a new CA key and cert (see `scripts/provision-tpm-devid.sh` header for the
   openssl command)
2. Store the new key in 1Password (replace the existing item)
3. Replace `devid-ca.pem` in this directory and commit
4. Re-run `scripts/provision-tpm-devid.sh` on all six nodes to re-issue DevID certs
5. Update the SPIRE server ConfigMap with the new CA cert and roll the StatefulSet
6. Re-run SPIRE registration jobs (existing agent entries are invalidated)

## Regenerating the EK CA Bundle

If new node hardware is added with a different TPM manufacturer, fetch the new EK CA
certs from the AIA extension of that node's EK cert:

`sudo tpm2_getekcertificate -o /tmp/ek.crt && openssl x509 -in /tmp/ek.crt -inform DER -noout -text | grep "CA Issuers"`

Then append the new CA (and any parent CAs in its chain) to `endorsement-ca-bundle.pem`.
