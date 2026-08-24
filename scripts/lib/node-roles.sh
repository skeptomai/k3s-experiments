#!/usr/bin/env bash
# Single source of truth for k3s node roles in this cluster.
# Source this from other scripts:  source "$(dirname "$0")/lib/node-roles.sh"
#
# Topology (since 2026-07-05, ipc1-3 retired — i5-12500T nodes promoted):
#   See docs/migrate-control-plane-to-elite-minis.md for migration history.
#   - SERVER nodes  : ipc4 (embedded-etcd cluster-init seed) + ipc5/ipc6 (join).
#                     Run the `k3s` (server) systemd unit; control-plane,etcd.
#   - AGENT nodes   : ipc7/ipc8/ipc9. Run the `k3s-agent` unit; carry workloads.
#
# Consult these helpers instead of re-encoding roles in scripts.

# The cluster-init seed (the one server installed with `cluster-init: true`).
CLUSTER_INIT_NODE="ipc4"

# Control-plane / etcd members.
SERVER_NODES=(ipc4 ipc5 ipc6)
# Worker / agent nodes (LAN, "fastest" tier).
AGENT_NODES=(ipc7 ipc8 ipc9)
# Cloud-hosted agent nodes -- SSH/admin reached over Tailscale, cluster
# traffic reached via a site-to-site WireGuard tunnel to the LAN (not the
# ipc4-jump pattern used for ipc7-9) -- see docs/aws-graviton-build-node.md.
# Kept separate from AGENT_NODES since they're a different network path,
# config (config/k3s-agent-cloud.yaml), and node-class label -- scripts that
# need "the LAN fastest tier" specifically (label-nodes.sh) should not
# silently pick these up too.
CLOUD_AGENT_NODES=(aws-graviton-build)

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
