#!/usr/bin/env bash
# Install KubeVirt node prerequisites on ipc nodes.
#
# KubeVirt's virt-handler DaemonSet bind-mounts several host paths that must
# pre-exist. containerd creates missing HostPath source directories automatically
# (type: ""), but Pelagos CRI does not (pelagos-containers/pelagos#445). Until
# that is fixed, these directories must be created manually on each node.
#
# Volatile paths (/var/run/kubevirt*) are recreated at boot via tmpfiles.d.
# The persistent path (/var/lib/kubevirt-node-labeller) is created once.
#
# Not called by reinstall-nodes.sh — run explicitly when deploying KubeVirt.
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

# Persistent: written by node-labeller init container on first virt-handler run
mkdir -p /var/lib/kubevirt-node-labeller
echo "  /var/lib/kubevirt-node-labeller: ok"

# Volatile: recreated at boot by tmpfiles.d
cat > /etc/tmpfiles.d/kubevirt.conf << 'EOF'
# KubeVirt virt-handler HostPath volumes — created here because Pelagos CRI
# does not auto-create missing HostPath source dirs (pelagos#445).
# Remove once pelagos#445 is fixed.
d /var/run/kubevirt                  0755 root root -
d /var/run/kubevirt-private          0755 root root -
d /var/run/kubevirt-libvirt-runtimes 0755 root root -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/kubevirt.conf
echo "  /var/run/kubevirt*: ok (tmpfiles.d installed)"
ENDSSH
  echo "  $node: done"
}

for node in "${NODES[@]}"; do
  configure_node "$node"
done
