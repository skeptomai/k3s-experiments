#!/usr/bin/env bash
# Install monitoring prerequisites on ipc nodes.
# Currently: lm-sensors + coretemp kernel module (CPU and NVMe temperature
# reporting via node-exporter's hwmon collector → Prometheus).
#
# coretemp exposes Intel per-core and package temperatures via the kernel hwmon
# interface. node-exporter picks these up automatically as node_hwmon_temp_celsius.
# The module is added to /etc/modules for persistence across reboots.
#
# Run from omen after any node reinstall. Called automatically by reinstall-nodes.sh.
# Usage: install-node-monitoring.sh [node...]   (default: ALL six nodes)
set -euo pipefail

NODES=("$@")
[[ ${#NODES[@]} -eq 0 ]] && NODES=(ipc4 ipc5 ipc6 ipc7 ipc8 ipc9)

IPC4_HOST="cb@ipc4.taildd208.ts.net"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
declare -A NODE_IP=([ipc4]="192.168.88.55" [ipc5]="192.168.88.56" [ipc6]="192.168.88.57" [ipc7]="192.168.88.63" [ipc8]="192.168.88.64" [ipc9]="192.168.88.65")

configure_node() {
  local node="$1"
  local ssh_cmd
  if [[ "$node" == "ipc4" ]]; then
    ssh_cmd="ssh $SSH_OPTS $IPC4_HOST"
  else
    ssh_cmd="ssh $SSH_OPTS -J $IPC4_HOST cb@${NODE_IP[$node]}"
  fi

  echo "Configuring monitoring prereqs on $node..."
  $ssh_cmd "sudo bash -s" << 'ENDSSH'
set -euo pipefail
apt-get install -y lm-sensors -q
# Load coretemp now and persist it across reboots
modprobe coretemp
grep -q '^coretemp$' /etc/modules 2>/dev/null || echo coretemp >> /etc/modules
echo "  coretemp: loaded and persistent"
# Verify sensors are readable
sensors 2>/dev/null | grep -E 'Package id|Composite' || true
ENDSSH
  echo "  $node: done"
}

for node in "${NODES[@]}"; do
  configure_node "$node"
done
