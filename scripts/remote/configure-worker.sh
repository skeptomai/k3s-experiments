#!/usr/bin/env bash
# Locks down SSH on a k3s worker node to accept connections only from the
# bastion host (ipc1), and configures UFW to allow k3s inter-node traffic.
# Runs directly on the worker node. Safe to run multiple times.
set -euo pipefail

BASTION_IP="192.168.88.53"
LAN_SUBNET="192.168.88.0/24"
SSH_CONF="/etc/ssh/sshd_config.d/10-bastion-lockdown.conf"

# ── SSH lockdown ───────────────────────────────────────────────────────────────

DESIRED="# Worker SSH lockdown
# Managed by k3s-experiments/scripts/remote/configure-worker.sh — do not edit manually.
# Only allows SSH connections originating from the bastion host (ipc1).
AllowUsers cb@${BASTION_IP}"

if [ -f "$SSH_CONF" ] && [ "$(sudo cat "$SSH_CONF")" = "$DESIRED" ]; then
    echo "SSH lockdown config already up to date."
else
    echo "$DESIRED" | sudo tee "$SSH_CONF" > /dev/null
    sudo sshd -t
    sudo systemctl reload ssh
    echo "SSH lockdown config applied and sshd reloaded."
fi

# ── UFW ───────────────────────────────────────────────────────────────────────

ufw_rule_exists() {
    sudo ufw status numbered | grep -qF "$1"
}

# SSH: allow from bastion only, deny everything else
if ! ufw_rule_exists "${BASTION_IP}.*22"; then
    sudo ufw allow from "$BASTION_IP" to any port 22 proto tcp comment "ssh-bastion"
    echo "UFW: allow SSH from bastion."
else
    echo "UFW: SSH allow rule already present."
fi

if ! ufw_rule_exists "22/tcp.*DENY"; then
    sudo ufw deny 22/tcp comment "deny-direct-ssh"
    echo "UFW: deny direct SSH."
else
    echo "UFW: SSH deny rule already present."
fi

# k3s inter-node ports
# 10250/TCP — kubelet API (server → worker)
if ! ufw_rule_exists "10250"; then
    sudo ufw allow from "$LAN_SUBNET" to any port 10250 proto tcp comment "k3s-kubelet"
    echo "UFW: allow kubelet (10250/TCP) from LAN."
else
    echo "UFW: kubelet rule already present."
fi

# 8472/UDP — Flannel VXLAN overlay (all nodes)
if ! ufw_rule_exists "8472"; then
    sudo ufw allow from "$LAN_SUBNET" to any port 8472 proto udp comment "k3s-flannel-vxlan"
    echo "UFW: allow Flannel VXLAN (8472/UDP) from LAN."
else
    echo "UFW: Flannel VXLAN rule already present."
fi

# Set defaults and enable
sudo ufw default deny incoming
sudo ufw default allow outgoing

if ! sudo ufw status | grep -q "Status: active"; then
    sudo ufw --force enable
    echo "UFW enabled."
else
    echo "UFW already active."
fi

echo "UFW status:"
sudo ufw status numbered
