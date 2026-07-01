#!/usr/bin/env bash
# Single source of truth for k3s node roles in this cluster.
# Source this from other scripts:  source "$(dirname "$0")/lib/node-roles.sh"
#
# Topology (since 2026-06-28, HA control plane — see
# docs/ipc1-3-control-plane-ha-runbook.md):
#   - SERVER nodes  : ipc1 (embedded-etcd cluster-init seed) + ipc2/ipc3 (join).
#                     Run the `k3s` (server) systemd unit; control-plane,etcd.
#   - AGENT nodes   : ipc4/ipc5/ipc6. Run the `k3s-agent` unit; carry workloads.
#
# Before this date the model was "ipc1 = sole server, ipc2-6 = agents"; many
# scripts hard-coded that. Consult these helpers instead of re-encoding roles.

# The cluster-init seed (the one server installed with `cluster-init: true`).
CLUSTER_INIT_NODE="ipc1"

# Control-plane / etcd members.
SERVER_NODES=(ipc1 ipc2 ipc3)
# Worker / agent nodes.
AGENT_NODES=(ipc4 ipc5 ipc6 ipc7 ipc8 ipc9)

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
