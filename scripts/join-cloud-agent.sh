#!/usr/bin/env bash
# Joins a cloud-hosted k3s agent node -- not the LAN jump-through-ipc4
# pattern scripts/upgrade-agents.sh uses for ipc7-9. Reached over Tailscale
# for SSH/admin (must already be joined under a MagicDNS name matching its
# intended k3s node name), but cluster traffic uses the site-to-site
# WireGuard tunnel to the home LAN (k3s-experiments#20) -- the node's actual
# k3s node-ip (its VPC-routable private IP) is set via `node-ip:` in
# config/k3s-agent-cloud.yaml, deployed separately by install-pelagos.sh,
# NOT as an exec arg here. (k3s merges an exec-arg node-ip with config.yaml's
# rather than one overriding the other, producing an invalid
# comma-separated value if both are set -- keep it in exactly one place.)
# Left unset here, k3s auto-detects the node's primary interface IP, which
# for an EC2 instance is already its VPC private IP -- the right default.
#
# K3S_URL points at ipc4 directly, NOT the kube-vip VIP -- the VIP is
# LAN-only (floating L2/ARP address) and unreachable from a cloud node even
# with the WireGuard tunnel. This makes control-plane connectivity for this
# one agent non-HA (single point of failure on ipc4 reachability), same as
# the `default` kubeconfig context already is.
#
# Usage: ./join-cloud-agent.sh <node-hostname> [ssh-user]
#   node-hostname: k3s node name == Tailscale MagicDNS name (no domain)
#   ssh-user:      default "ubuntu" (Canonical AMI default user)
set -euo pipefail

SERVER="ipc4.taildd208.ts.net"
SERVER_URL="https://ipc4.taildd208.ts.net:6443"

NODE="${1:?usage: join-cloud-agent.sh <node-hostname> [ssh-user]}"
NODE_USER="${2:-ubuntu}"

echo "=== Fetching cluster token + version from $SERVER ==="
TOKEN=$(ssh -o StrictHostKeyChecking=no cb@"$SERVER" \
    "sudo cat /var/lib/rancher/k3s/server/node-token")
K3S_VERSION=$(ssh -o StrictHostKeyChecking=no cb@"$SERVER" "k3s --version | awk 'NR==1{print \$3}'")
echo "  pinning to $K3S_VERSION"

echo "=== Clearing stale node password secret for $NODE ==="
ssh -o StrictHostKeyChecking=no cb@"$SERVER" \
    "sudo kubectl delete secret ${NODE}.node-password.k3s -n kube-system 2>/dev/null && echo Deleted || echo 'Not present, skipping'"

echo "=== Installing k3s agent on $NODE -> $K3S_VERSION ==="
# --node-name is explicit, not left to default to the OS hostname -- cloud
# images (e.g. Canonical's Ubuntu AMI) otherwise register as ip-x-x-x-x.
ssh -o StrictHostKeyChecking=no "$NODE_USER@${NODE}.taildd208.ts.net" \
    "curl -sfL https://get.k3s.io | sudo K3S_URL=$SERVER_URL K3S_TOKEN=$TOKEN INSTALL_K3S_VERSION=$K3S_VERSION sh -s - agent --node-name=$NODE --node-taint=cloud=aws:NoSchedule"

echo "Done: $NODE"
