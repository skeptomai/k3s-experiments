#!/usr/bin/env bash
# Install KubeVirt node prerequisites on ipc nodes.
#
# Creates /var/lib/kubevirt-node-labeller on each node. KubeVirt's virt-handler
# init container bind-mounts this path (hostPath type "") and writes the node's
# KVM capability files into it. It must exist before the first virt-handler run;
# after that virt-handler manages it. Pelagos v0.65.50+ auto-creates it (#445
# fixed), but the directory may still be absent on nodes that have never run
# virt-handler before — this script ensures it exists.
#
# Not called by reinstall-nodes.sh — run once explicitly when deploying KubeVirt.
# Usage: install-kubevirt-node-prereqs.sh [node...]   (default: ALL six nodes)
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

  echo "Configuring KubeVirt node prereqs on $node..."
  $ssh_cmd "sudo bash -s" << 'ENDSSH'
set -euo pipefail
mkdir -p /var/lib/kubevirt-node-labeller
echo "  /var/lib/kubevirt-node-labeller: ok"
ENDSSH
  echo "  $node: done"
}

for node in "${NODES[@]}"; do
  configure_node "$node"
done
