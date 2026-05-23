#!/usr/bin/env bash
# Configures ipc1 as a bastion host.
# Runs directly on ipc1. Safe to run multiple times.
set -euo pipefail

CONF="/etc/ssh/sshd_config.d/10-bastion.conf"

DESIRED="# Bastion host SSH config
# Managed by k3s-experiments/scripts/remote/configure-bastion.sh — do not edit manually.
AllowTcpForwarding yes
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no"

if [ -f "$CONF" ] && [ "$(sudo cat "$CONF")" = "$DESIRED" ]; then
    echo "Bastion SSH config already up to date."
else
    echo "$DESIRED" | sudo tee "$CONF" > /dev/null
    sudo sshd -t
    sudo systemctl reload ssh
    echo "Bastion SSH config applied and sshd reloaded."
fi
