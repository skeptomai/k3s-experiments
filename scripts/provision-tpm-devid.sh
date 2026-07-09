#!/usr/bin/env bash
# Provision a TPM DevID key and certificate on a single ipc node.
#
# Run from omen. Generates a TPM-bound DevID key on the target node, brings
# the CSR back to omen, signs it with the DevID CA key (retrieved from
# 1Password), and installs the cert on the node.
#
# Usage: bash scripts/provision-tpm-devid.sh <node>
#   e.g. bash scripts/provision-tpm-devid.sh ipc5
#
# Prerequisites on omen:
#   - 1Password CLI (op) authenticated
#   - DevID CA key stored in 1Password as "ipc-cluster DevID CA key" (notes field)
#   - DevID CA cert at config/tpm/devid-ca.pem
#
# Prerequisites on node:
#   - tpm2-tools installed (apt install tpm2-tools)
#   - /etc/spire/ directory writable by root
#
# Idempotent: if a valid cert already exists at /etc/spire/devid.crt on the
# node (valid for >30 days, signed by our DevID CA), the script exits cleanly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEVID_CA_CERT="${REPO_ROOT}/config/tpm/devid-ca.pem"
NODE="${1:-}"

if [[ -z "$NODE" ]]; then
  echo "Usage: $0 <node>" >&2
  exit 1
fi

# Resolve SSH target: ipc4 is direct via tailnet, others jump through ipc4
if [[ "$NODE" == "ipc4" ]]; then
  SSH_TARGET="cb@ipc4.taildd208.ts.net"
  SSH_OPTS="-i ${HOME}/.ssh/id_rsa -o StrictHostKeyChecking=no"
else
  SSH_TARGET="cb@${NODE}"
  SSH_OPTS="-i ${HOME}/.ssh/id_rsa -o StrictHostKeyChecking=no -J cb@ipc4.taildd208.ts.net"
fi

ssh_node() { ssh $SSH_OPTS "$SSH_TARGET" "$@"; }
scp_from_node() { scp $SSH_OPTS "${SSH_TARGET}:$1" "$2"; }
scp_to_node() { scp $SSH_OPTS "$1" "${SSH_TARGET}:$2"; }

echo "==> Checking for existing DevID cert on ${NODE}..."
if ssh_node "sudo test -f /etc/spire/devid.crt" 2>/dev/null; then
  EXPIRY=$(ssh_node "sudo openssl x509 -in /etc/spire/devid.crt -noout -checkend 2592000 2>/dev/null && echo valid || echo expiring")
  ISSUER=$(ssh_node "sudo openssl x509 -in /etc/spire/devid.crt -noout -issuer 2>/dev/null")
  if [[ "$EXPIRY" == "valid" ]] && echo "$ISSUER" | grep -q "ipc-cluster DevID CA"; then
    echo "    DevID cert exists and is valid (>30 days). Nothing to do."
    exit 0
  fi
  echo "    Existing cert is expiring or from a different CA — reprovisioning."
fi

echo "==> Ensuring /etc/spire exists on ${NODE}..."
ssh_node "sudo mkdir -p /etc/spire && sudo chmod 700 /etc/spire"

echo "==> Ensuring tpm2-openssl provider is installed on ${NODE}..."
ssh_node "sudo apt-get install -y tpm2-openssl -qq 2>/dev/null"

echo "==> Generating TPM DevID key and CSR on ${NODE}..."
NODE_CN="spire-agent-${NODE}.ipc.local"
ssh_node "sudo bash -s" << REMOTE_EOF
set -euo pipefail

TPM_DIR=/etc/spire
DEVID_HANDLE=0x81010001  # persistent NV handle; evicted after CSR generation

# Create SRK (Storage Root Key) primary under the Owner hierarchy.
# Parameters MUST match SPIRE's internal SRKTemplateHighRSA() from go-tpm-tools:
#   HandleOwner, RSA 2048, SHA-256, AES-128-CFB symmetric, restricted|decrypt
# The primary is deterministic: same params on same TPM = same key handle.
tpm2_createprimary \
  -C o \
  -g sha256 \
  -G rsa \
  -a "fixedtpm|fixedparent|sensitivedataorigin|userwithauth|noda|restricted|decrypt" \
  -c /tmp/tpm_primary.ctx \
  -Q

# Create DevID key under the SRK (RSA 2048, unrestricted sign — unrestricted so
# tpm2-openssl can use it to sign the CSR; SPIRE loads it for attestation signing)
tpm2_create \
  -C /tmp/tpm_primary.ctx \
  -g sha256 \
  -G "rsa:rsassa" \
  -a "fixedtpm|fixedparent|sensitivedataorigin|userwithauth|noda|sign" \
  -r \${TPM_DIR}/devid.priv \
  -u \${TPM_DIR}/devid.pub \
  -Q

# Load key into TPM (tpm2_load expects TPM2B_PUBLIC with 2-byte size prefix)
tpm2_load -C /tmp/tpm_primary.ctx -r \${TPM_DIR}/devid.priv -u \${TPM_DIR}/devid.pub -c /tmp/devid.ctx -Q
# Evict any stale handle at this address before persisting
tpm2_evictcontrol -C o -c \${DEVID_HANDLE} 2>/dev/null || true
tpm2_evictcontrol -C o -c /tmp/devid.ctx \${DEVID_HANDLE} -Q

# Generate CSR using tpm2 OpenSSL provider — the private key signs the CSR inside the TPM
openssl req \
  -provider tpm2 -provider default \
  -key "handle:\${DEVID_HANDLE}" \
  -new \
  -out /tmp/devid.csr \
  -subj "/CN=${NODE_CN}/O=ipc.local" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature"

# Evict the persistent handle — SPIRE uses the blob files, not the handle
tpm2_evictcontrol -C o -c \${DEVID_HANDLE} -Q

# tpm2_create outputs TPM2B_PUBLIC/TPM2B_PRIVATE (2-byte size prefix + payload).
# SPIRE's go-tpm library adds the prefix itself via U16Bytes(), so the files
# must contain raw payload only. Strip both prefixes now that tpm2_load is done.
dd if=\${TPM_DIR}/devid.pub  bs=1 skip=2 of=\${TPM_DIR}/devid.pub.raw  2>/dev/null && mv \${TPM_DIR}/devid.pub.raw  \${TPM_DIR}/devid.pub
dd if=\${TPM_DIR}/devid.priv bs=1 skip=2 of=\${TPM_DIR}/devid.priv.raw 2>/dev/null && mv \${TPM_DIR}/devid.priv.raw \${TPM_DIR}/devid.priv

# Export public key PEM for reference only (not used by SPIRE)
tpm2_readpublic -c /tmp/devid.ctx -f PEM -o \${TPM_DIR}/devid_pubkey.pem -Q 2>/dev/null || true

# Lock down permissions
chmod 600 \${TPM_DIR}/devid.priv \${TPM_DIR}/devid.pub
chmod 644 /tmp/devid.csr

rm -f /tmp/tpm_primary.ctx /tmp/devid.ctx
echo "TPM DevID key and CSR generated."
REMOTE_EOF

echo "==> Fetching CSR from ${NODE}..."
TMPDIR_LOCAL=$(mktemp -d)
trap "rm -rf ${TMPDIR_LOCAL}" EXIT
scp_from_node "/tmp/devid.csr" "${TMPDIR_LOCAL}/devid.csr"
ssh_node "sudo rm -f /tmp/devid.csr"

echo "==> Retrieving DevID CA key from 1Password..."
op item get "ipc-cluster DevID CA key" --fields notesPlain --reveal | tr -d '"' > "${TMPDIR_LOCAL}/devid-ca.key.pem"
chmod 600 "${TMPDIR_LOCAL}/devid-ca.key.pem"

echo "==> Signing CSR with DevID CA..."
openssl x509 -req \
  -in "${TMPDIR_LOCAL}/devid.csr" \
  -CA "${DEVID_CA_CERT}" \
  -CAkey "${TMPDIR_LOCAL}/devid-ca.key.pem" \
  -CAcreateserial \
  -out "${TMPDIR_LOCAL}/devid.crt" \
  -days 3650 \
  -sha256 \
  -extfile <(printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nsubjectAltName=URI:spiffe://ipc.local/spire/agent/tpm_devid/${NODE}\n") \
  -copy_extensions none 2>/dev/null

echo "    Signed cert:"
openssl x509 -in "${TMPDIR_LOCAL}/devid.crt" -noout -subject -issuer -dates

echo "==> Installing cert on ${NODE}..."
scp_to_node "${TMPDIR_LOCAL}/devid.crt" "/tmp/devid.crt"
ssh_node "sudo mv /tmp/devid.crt /etc/spire/devid.crt && sudo chmod 644 /etc/spire/devid.crt"

echo "==> Verifying installation on ${NODE}..."
ssh_node "sudo openssl verify -CAfile /dev/stdin /etc/spire/devid.crt" < "${DEVID_CA_CERT}"

echo "==> Installing server bundle-signing public key on ${NODE}..."
# The server's bundle-signing public key is fetched from ipc4 (handle 0x81008006)
# and written to /etc/spire/ on every node — this is the out-of-band trust anchor
# that lets agents verify the SPIRE server's trust bundle without trusting Kubernetes.
SERVER_PUB=$(ssh -i "${HOME}/.ssh/id_rsa" -o StrictHostKeyChecking=no \
  cb@ipc4.taildd208.ts.net "sudo tpm2_readpublic -c 0x81008006 -f pem 2>/dev/null")
if [[ -z "$SERVER_PUB" ]]; then
  echo "  WARN: could not read server bundle-signing public key from ipc4 TPM."
  echo "        Run 'bash scripts/provision-server-bundle-signing.sh' first."
else
  echo "$SERVER_PUB" | ssh_node "sudo tee /etc/spire/server-bundle-signing.pub > /dev/null && sudo chmod 644 /etc/spire/server-bundle-signing.pub"
  echo "  /etc/spire/server-bundle-signing.pub written"
fi

echo ""
echo "DevID provisioning complete for ${NODE}."
echo "Files on node:"
echo "  /etc/spire/devid.crt                — signed DevID certificate (PEM)"
echo "  /etc/spire/devid.priv               — TPM private key blob"
echo "  /etc/spire/devid.pub                — TPM public key blob"
echo "  /etc/spire/devid_pubkey.pem         — public key (PEM, for reference)"
echo "  /etc/spire/server-bundle-signing.pub — server TPM public key (out-of-band trust anchor)"
