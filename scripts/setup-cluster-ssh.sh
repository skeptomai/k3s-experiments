#!/usr/bin/env bash
# Configures bastion host and worker lockdown in the correct order.
# Run from any machine with SSH access to ipc4 via the tailnet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/setup-bastion.sh"
echo ""
bash "$SCRIPT_DIR/setup-workers.sh"
