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

echo "==> Generating TPM DevID key on ${NODE}..."
ssh_node "sudo bash -s" << 'REMOTE_EOF'
set -euo pipefail

TPM_DIR=/etc/spire

# Create primary key under Endorsement hierarchy
tpm2_createprimary -C e -g sha256 -G ecc -c /tmp/tpm_primary.ctx -Q

# Create DevID key under primary (ECC P-256, restricted=false so it can sign arbitrary data)
tpm2_create \
  -C /tmp/tpm_primary.ctx \
  -g sha256 \
  -G ecc \
  -a "fixedtpm|fixedparent|sensitivedataorigin|userwithauth|sign|noda" \
  -r ${TPM_DIR}/devid.priv \
  -u ${TPM_DIR}/devid.pub \
  -Q

# Load key and export public key as PEM for CSR generation
tpm2_load -C /tmp/tpm_primary.ctx -r ${TPM_DIR}/devid.priv -u ${TPM_DIR}/devid.pub -c /tmp/devid.ctx -Q
tpm2_readpublic -c /tmp/devid.ctx -f PEM -o ${TPM_DIR}/devid_pubkey.pem -Q

# Lock down permissions
chmod 600 ${TPM_DIR}/devid.priv ${TPM_DIR}/devid.pub ${TPM_DIR}/devid_pubkey.pem

# Clean up context files (not needed after key is persisted as blobs)
rm -f /tmp/tpm_primary.ctx /tmp/devid.ctx

echo "TPM DevID key generated."
REMOTE_EOF

echo "==> Generating CSR on ${NODE}..."
NODE_CN="spire-agent-${NODE}.ipc.local"
ssh_node "sudo bash -s" << REMOTE_CSR_EOF
set -euo pipefail
openssl req -new \
  -key /etc/spire/devid_pubkey.pem \
  -out /tmp/devid.csr \
  -subj "/CN=${NODE_CN}/O=ipc.local" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature"
chmod 644 /tmp/devid.csr
echo "CSR generated."
REMOTE_CSR_EOF

echo "==> Fetching CSR from ${NODE}..."
TMPDIR_LOCAL=$(mktemp -d)
trap "rm -rf ${TMPDIR_LOCAL}" EXIT
scp_from_node "/tmp/devid.csr" "${TMPDIR_LOCAL}/devid.csr"
ssh_node "sudo rm -f /tmp/devid.csr"

echo "==> Retrieving DevID CA key from 1Password..."
op item get "ipc-cluster DevID CA key" --fields notesPlain --reveal > "${TMPDIR_LOCAL}/devid-ca.key.pem"
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

echo ""
echo "DevID provisioning complete for ${NODE}."
echo "Files on node:"
echo "  /etc/spire/devid.crt   — signed DevID certificate (PEM)"
echo "  /etc/spire/devid.priv  — TPM private key blob"
echo "  /etc/spire/devid.pub   — TPM public key blob"
echo "  /etc/spire/devid_pubkey.pem — public key (PEM, for reference)"
