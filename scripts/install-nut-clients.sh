#!/usr/bin/env bash
# Install and configure NUT client (upsmon) on ipc nodes.
# Connects each node to the NUT server running on nazgul (192.168.89.2).
# Run from omen after any node reinstall.
# Usage: install-nut-clients.sh [node...]   (default: ipc1 ipc2 ipc3)
set -euo pipefail

NODES=("${@:-ipc1 ipc2 ipc3}")
NUT_SERVER="192.168.89.2"
UPS_NAME="cyberpower"
MON_USER="upsmon"
MON_PWD="upsmon123"

configure_node() {
  local node="$1"
  local ssh_cmd

  if [[ "$node" == "ipc1" ]]; then
    ssh_cmd="ssh -o StrictHostKeyChecking=no cb@ipc1.taildd208.ts.net"
  else
    ssh_cmd="ssh -o StrictHostKeyChecking=no -J cb@ipc1.taildd208.ts.net cb@$node"
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
systemctl restart nut-monitor
systemctl is-active nut-monitor
ENDSSH
  echo "  $node: done"
}

for node in "${NODES[@]}"; do
  configure_node "$node"
done
