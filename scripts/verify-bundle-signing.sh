#!/usr/bin/env bash
# Manually verify the TPM-signed trust bundle JWT served by spire-bundle-signing.
#
# Run from any ipc node. Fetches the signed JWT from the spire-bundle-signing
# ClusterIP Service, verifies the RS256 signature against the server's TPM
# public key at /etc/spire/server-bundle-signing.pub, and prints the SPIFFE
# trust bundle PEM if the signature is valid.
#
# This replicates exactly what the verify-bundle init container does at agent
# pod startup.
#
# Usage: bash scripts/verify-bundle-signing.sh [node]
#   e.g. run directly on a node: sudo bash /tmp/verify-bundle-signing.sh
#   e.g. run via ssh from omen:  bash scripts/verify-bundle-signing.sh ipc5

set -euo pipefail

BUNDLE_URL="http://10.43.243.176/spiffetrustbundle.token"
PUB_KEY="/etc/spire/server-bundle-signing.pub"

# If a node argument is given, copy and run the script there via SSH
if [[ "${1:-}" != "" ]]; then
  NODE="$1"
  if [[ "$NODE" == "ipc4" ]]; then
    SSH_OPTS="-i ${HOME}/.ssh/id_rsa -o StrictHostKeyChecking=no"
    SSH_TARGET="cb@ipc4.taildd208.ts.net"
  else
    SSH_OPTS="-i ${HOME}/.ssh/id_rsa -o StrictHostKeyChecking=no -J cb@ipc4.taildd208.ts.net"
    SSH_TARGET="cb@${NODE}"
  fi
  scp $SSH_OPTS "$0" "${SSH_TARGET}:/tmp/verify-bundle-signing.sh"
  ssh $SSH_OPTS "$SSH_TARGET" "sudo bash /tmp/verify-bundle-signing.sh"
  exit 0
fi

# --- Running on the node ---

echo "==> Fetching signed bundle JWT from ${BUNDLE_URL}..."
TOKEN=$(curl -sf "${BUNDLE_URL}")
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: empty response from ${BUNDLE_URL}" >&2
  exit 1
fi
echo "    OK ($(echo -n "$TOKEN" | wc -c) bytes)"

echo "==> Splitting JWT into header.payload and signature..."
HEADER_PAYLOAD=$(echo "$TOKEN" | cut -d. -f1,2)
SIG_B64=$(echo "$TOKEN" | cut -d. -f3)

printf '%s' "$HEADER_PAYLOAD" > /tmp/jwtdata

# Base64url decode the signature (add padding, replace - and _ with + and /)
python3 -c "
import sys, base64
s = '${SIG_B64}'.replace('-', '+').replace('_', '/')
s += '=' * (-len(s) % 4)
open('/tmp/jwtsig', 'wb').write(base64.b64decode(s))
"

echo "==> Verifying RS256 signature against ${PUB_KEY}..."
if openssl dgst -sha256 -verify "${PUB_KEY}" -signature /tmp/jwtsig /tmp/jwtdata; then
  echo "    Signature valid — bundle is signed by the server's TPM key."
else
  echo "ERROR: signature verification FAILED" >&2
  rm -f /tmp/jwtdata /tmp/jwtsig
  exit 1
fi

echo "==> Decoding JWT payload..."
PAYLOAD_B64=$(echo "$TOKEN" | cut -d. -f2)
PAYLOAD=$(python3 -c "
import sys, base64, json
s = '${PAYLOAD_B64}'.replace('-', '+').replace('_', '/')
s += '=' * (-len(s) % 4)
data = json.loads(base64.b64decode(s))
print(json.dumps({k: v for k, v in data.items() if k != 'spiffetb'}, indent=2))
")
echo "    JWT claims (trust bundle omitted):"
echo "$PAYLOAD" | sed 's/^/    /'

echo "==> Extracting trust bundle PEM..."
BUNDLE=$(python3 -c "
import sys, base64, json
s = '${PAYLOAD_B64}'.replace('-', '+').replace('_', '/')
s += '=' * (-len(s) % 4)
data = json.loads(base64.b64decode(s))
print(data.get('spiffetb', ''))
")
echo "    Trust bundle subject:"
echo "$BUNDLE" | openssl x509 -noout -subject -issuer -dates 2>/dev/null | sed 's/^/    /'

echo ""
echo "Bundle signature verification complete."
rm -f /tmp/jwtdata /tmp/jwtsig
