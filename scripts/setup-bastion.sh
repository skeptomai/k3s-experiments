#!/usr/bin/env bash
# Configures ipc1 as a bastion host.
# Run from any machine with SSH access to ipc1 via the tailnet.
set -euo pipefail

SERVER="ipc1.taildd208.ts.net"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Configuring ipc1 as bastion host ==="
scp -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no \
    "$SCRIPT_DIR/remote/configure-bastion.sh" \
    cb@"$SERVER":/tmp/configure-bastion.sh

ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no cb@"$SERVER" \
    "bash /tmp/configure-bastion.sh; rm /tmp/configure-bastion.sh"

echo "=== Done ==="
