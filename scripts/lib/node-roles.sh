#!/usr/bin/env bash
# Single source of truth for k3s node roles in this cluster.
# Source this from other scripts:  source "$(dirname "$0")/lib/node-roles.sh"
#
# Topology (post-migration, all-Elite-Mini 6-node — see
# docs/migrate-control-plane-to-elite-minis.md; the Pentiums ipc1-3 were retired):
#   - SERVER nodes  : ipc4 (embedded-etcd cluster-init seed) + ipc5/ipc6 (join).
#                     Run the `k3s` (server) unit; control-plane,etcd + workloads
#                     (co-located, un-tainted).
#   - AGENT nodes   : ipc7/ipc8/ipc9. Run the `k3s-agent` unit; carry workloads.
#
# Prior model (2026-06-28..07): dedicated Pentium control plane ipc1-3 + agents
# ipc4-9. Many scripts hard-coded ipc1 as seed/bastion — consult these helpers.

# The cluster-init seed (the one server installed with `cluster-init: true`).
CLUSTER_INIT_NODE="ipc4"

# Control-plane / etcd members.
SERVER_NODES=(ipc4 ipc5 ipc6)
# Worker / agent nodes.
AGENT_NODES=(ipc7 ipc8 ipc9)

# is_server_node <node> -> 0 if the node is a control-plane server, else 1.
is_server_node() {
    local n=$1 s
    for s in "${SERVER_NODES[@]}"; do
        [[ "$s" == "$n" ]] && return 0
    done
    return 1
}

# k3s_role <node> -> prints "server" or "agent".
k3s_role() { is_server_node "$1" && echo server || echo agent; }

# k3s_service <node> -> prints the systemd unit name for the node's k3s role.
k3s_service() { is_server_node "$1" && echo k3s || echo k3s-agent; }
