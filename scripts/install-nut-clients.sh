#!/usr/bin/env bash
# Install and configure NUT client (upsmon) on ipc nodes.
# Connects each node to the NUT server running on ipc4 (192.168.88.55).
# ipc4 runs the NUT server with the UPS connected via USB; ipc5-9 are clients.
# NOTE: ipc4 itself runs upsmon as master — this script configures it as a slave
# client only when run on ipc4; for a fresh ipc4 reinstall, run
# scripts/install-nut-server.sh first, then this script for the other nodes.
# Run from omen after any node reinstall.
# Usage: install-nut-clients.sh [node...]   (default: ALL six nodes)
#
# NOTE (#8): all six nodes (incl. workers ipc4-6) run upsmon — reinstall-nodes.sh
# calls this per-node, so reinstalled workers get it automatically. For GRACEFUL pod
# termination on a UPS shutdown, kubelet graceful-node-shutdown must ALSO be enabled
# via the kubelet CONFIG FILE (`shutdownGracePeriod`) — NOT the removed
# `--shutdown-grace-period` flag, which fails to parse and crashes k3s. See #8.
set -euo pipefail

NODES=("$@")
[[ ${#NODES[@]} -eq 0 ]] && NODES=(ipc4 ipc5 ipc6 ipc7 ipc8 ipc9)
# SSH by IP (via the ipc4 jump). Node short-names only resolve for Tailscale-enrolled
# nodes; ipc7-9 (manual install) aren't on the tailnet, so name-based SSH fails.
declare -A NODE_IP=([ipc4]="192.168.88.55" [ipc5]="192.168.88.56" [ipc6]="192.168.88.57" [ipc7]="192.168.88.63" [ipc8]="192.168.88.64" [ipc9]="192.168.88.65")
NUT_SERVER="192.168.88.55"  # ipc4 — NUT server with USB-connected UPS
UPS_NAME="cyberpower"
MON_USER="upsmon"
MON_PWD="upsmon123"

configure_node() {
  local node="$1"
  local ssh_cmd

  if [[ "$node" == "ipc4" ]]; then
    ssh_cmd="ssh -o StrictHostKeyChecking=no cb@ipc4.taildd208.ts.net"
  else
    ssh_cmd="ssh -o StrictHostKeyChecking=no -J cb@ipc4.taildd208.ts.net cb@${NODE_IP[$node]}"
  fi

  echo "Configuring NUT client on $node..."
  $ssh_cmd "sudo bash -s" << ENDSSH
set -euo pipefail

apt-get install -y nut-client -q

cat > /etc/nut/nut.conf << 'EOF'
MODE=netclient
EOF

cat > /etc/nut/upsmon.conf << 'EOF'
MONITOR ${UPS_NAME}@${NUT_SERVER} 1 ${MON_USER} ${MON_PWD} slave
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POLLFREQ 5
POLLFREQALERT 5
DEADTIME 60
POWERDOWNFLAG /etc/killpower
NOCOMMWARNTIME 300
FINALDELAY 5
EOF

systemctl enable nut-monitor
# NUT 2.8.4 (Ubuntu 26.04): upsmon can fail a few times during install before
# /run/nut + the network are ready, tripping systemd's start-limit so the unit
# latches "failed" and a plain restart won't recover it. Clear the latch and
# retry so the install ends with nut-monitor actually active.
systemctl reset-failed nut-monitor 2>/dev/null || true
systemctl restart nut-monitor 2>/dev/null || (sleep 3; systemctl reset-failed nut-monitor; systemctl restart nut-monitor)
systemctl is-active nut-monitor || echo "WARN: nut-monitor not active on this node"
ENDSSH
  echo "  $node: done"
}

for node in "${NODES[@]}"; do
  configure_node "$node"
done
