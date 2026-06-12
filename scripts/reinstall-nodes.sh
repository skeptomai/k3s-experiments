#!/usr/bin/env bash
# PXE reinstall one or more ipc worker nodes.
# Drives the full cycle: deploy PXE configs → clear dynamic DHCP leases →
# enable PXE → reboot → wait for OS install → disable PXE → clear known_hosts
# → rejoin k3s → verify.
#
# Run from omen (or any machine with SSH to ipc1 via tailnet).
# ipc1 is NEVER safe to reinstall with this script — it requires a full manual
# cluster rebuild (wipes etcd).
#
# Note: ipc4/ipc5 require "Network Boot" enabled in BIOS firmware settings
# (separate from efibootmgr boot order) — one-time physical setup.
#
# Usage: ./reinstall-nodes.sh <node> [node...]
#   node: ipc2 | ipc3 | ipc4 | ipc5
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="ipc1.taildd208.ts.net"
MIKROTIK="admin@192.168.88.1"

declare -A NODE_IP=([ipc2]="192.168.88.52" [ipc3]="192.168.88.54" [ipc4]="192.168.88.55" [ipc5]="192.168.88.56" [ipc6]="192.168.88.57")
declare -A NODE_NIC=([ipc2]="enp2s0" [ipc3]="enp2s0" [ipc4]="eno1" [ipc5]="eno1" [ipc6]="eno1")
declare -A NODE_MAC=([ipc2]="A8:A1:59:43:2A:ED" [ipc3]="A8:A1:59:43:2A:74" [ipc4]="D0:AD:08:9C:D2:CB" [ipc5]="D0:AD:08:9C:D1:45" [ipc6]="E0:73:E7:C0:B0:08")

NODES=("$@")
[[ ${#NODES[@]} -eq 0 ]] && { echo "Usage: $0 <node> [node...]"; exit 1; }

for node in "${NODES[@]}"; do
    if [[ "$node" == "ipc1" ]]; then
        echo "ERROR: ipc1 is the control plane. Reinstalling it wipes etcd — use the manual runbook." >&2
        exit 1
    fi
    if [[ -z "${NODE_IP[$node]+x}" ]]; then
        echo "ERROR: unknown node '$node'. Valid nodes: ipc2 ipc3 ipc4 ipc5 ipc6" >&2
        exit 1
    fi
done

ssh_ipc1() {
    ssh -o StrictHostKeyChecking=no cb@"$SERVER" "$@"
}

ssh_node() {
    local node=$1; shift
    ssh -o StrictHostKeyChecking=no -J cb@"$SERVER" cb@"${NODE_IP[$node]}" "$@"
}

node_ssh_up() {
    local node=$1
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -J cb@"$SERVER" cb@"${NODE_IP[$node]}" true 2>/dev/null
}

wait_node_offline() {
    local node=$1
    echo "--- Waiting for $node to go offline (up to 5 min) ---"
    local i=0
    # For nodes not yet in k3s, wait for SSH to drop instead
    if ! ssh_ipc1 "sudo kubectl get node $node --no-headers 2>/dev/null" | grep -q "Ready"; then
        echo "  $node not in k3s — waiting for SSH to drop (reboot confirmation)"
        until ! node_ssh_up "$node"; do
            sleep 5; i=$((i+1))
            [[ $i -gt 60 ]] && { echo "WARN: $node SSH never dropped — reboot may have failed"; return 1; }
        done
        echo "  $node is offline (SSH dropped)"
        return 0
    fi
    while ssh_ipc1 "sudo kubectl get node $node --no-headers 2>/dev/null" | grep -q "Ready"; do
        sleep 15; i=$((i+1))
        [[ $i -gt 20 ]] && { echo "WARN: $node still Ready after 5 min — may not have rebooted"; return 1; }
    done
    echo "  $node is offline"
}

wait_ssh_up() {
    local node=$1
    echo "--- Waiting for $node SSH to come back (autoinstall takes ~10 min) ---"
    echo "  Minimum 5 min wait to avoid false-positive on quick local-disk boot..."
    sleep 300
    local i=0
    until node_ssh_up "$node"; do
        printf "  waiting... (%d min elapsed)\r" $(( (i * 30 + 300) / 60 ))
        sleep 30; i=$((i+1))
        [[ $i -gt 30 ]] && { echo ""; echo "ERROR: $node SSH never came back after 20 min"; exit 1; }
    done
    echo ""
    echo "  $node SSH is up"
}

wait_node_ready() {
    local node=$1
    echo "--- Waiting for $node to appear Ready in kubectl (up to 5 min) ---"
    local i=0
    until ssh_ipc1 "sudo kubectl get node $node --no-headers 2>/dev/null" | grep -q "Ready"; do
        sleep 15; i=$((i+1))
        [[ $i -gt 20 ]] && { echo "ERROR: $node not Ready in kubectl after 5 min"; exit 1; }
    done
    echo "  $node is Ready"
}

run_privileged_pod() {
    local node=$1 pod=$2 cmd=$3
    ssh_ipc1 "sudo kubectl run $pod \
        --image=alpine \
        --overrides='{\"spec\":{\"nodeName\":\"$node\",\"hostPID\":true,\"containers\":[{\"name\":\"r\",\"image\":\"alpine\",\"command\":[\"nsenter\",\"--mount=/proc/1/ns/mnt\",\"--\",\"sh\",\"-c\",\"$cmd\"],\"securityContext\":{\"privileged\":true}}]}}' \
        --restart=Never -n default" 2>/dev/null || true
    sleep 3
    ssh_ipc1 "sudo kubectl delete pod $pod -n default --ignore-not-found 2>/dev/null" || true
}

set_pxe_bootnext_via_kubectl() {
    local node=$1
    local pod="pxe-bootnext-${node}-$$"
    echo "--- Setting PXE as next boot entry on $node via kubectl ---"
    # Find the first network/PXE boot entry and set it as bootnext so disk-first BIOS still PXE boots
    run_privileged_pod "$node" "$pod" \
        'entry=\$(efibootmgr | grep -iE "^Boot[0-9A-F]{4}\*.*([Nn]et[Bb]oot|iPXE|[Pp][Xx][Ee]|[Nn]etwork|[Ii][Pp][Vv]4)" | head -1 | grep -oE "[0-9A-F]{4}"); [ -n "\$entry" ] && efibootmgr --bootnext "\$entry" && echo "bootnext set to \$entry" || echo "no PXE entry found"'
}

set_pxe_bootnext_via_ssh() {
    local node=$1
    echo "--- Setting PXE as next boot entry on $node via SSH ---"
    # Use SUDO_ASKPASS workaround: sudo -n first (passwordless), fall through gracefully
    ssh_node "$node" 'entry=$(sudo -n efibootmgr 2>/dev/null | grep -iE "^Boot[0-9A-F]{4}\*.*([Nn]et[Bb]oot|iPXE|[Pp][Xx][Ee]|[Nn]etwork|[Ii][Pp][Vv]4)" | head -1 | grep -oE "[0-9A-F]{4}"); [ -n "$entry" ] && sudo -n efibootmgr --bootnext "$entry" && echo "bootnext set to $entry" || echo "no PXE entry found or sudo requires password, relying on boot order"'
}

reboot_via_kubectl() {
    local node=$1
    local pod="reboot-${node}-$$"
    echo "--- Rebooting $node via kubectl privileged pod (no SSH available) ---"
    run_privileged_pod "$node" "$pod" "reboot"
}

clear_dynamic_leases() {
    local node=$1
    local mac="${NODE_MAC[$node]}"
    echo "--- Clearing dynamic MikroTik DHCP leases for $node ($mac) ---"
    # MikroTik (192.168.88.1) is on the home LAN, not the tailnet, so jump
    # through ipc1 which is on both.
    ssh -o StrictHostKeyChecking=no -J cb@"$SERVER" "$MIKROTIK" \
        "/ip dhcp-server lease remove [find where mac-address=\"$mac\" dynamic=yes]" 2>/dev/null \
        && echo "  Dynamic leases cleared (or none existed)" || echo "  WARN: could not reach MikroTik"
}

echo "=== PXE Reinstall: ${NODES[*]} ==="
echo ""

echo "--- Deploying PXE configs to nazgul ---"
bash "$REPO_ROOT/scripts/deploy-pxe-configs.sh"

for node in "${NODES[@]}"; do
    echo ""
    echo "====== $node ======"

    clear_dynamic_leases "$node"

    echo "--- Removing stale Tailscale device(s) for $node (so it reclaims its name) ---"
    bash "$REPO_ROOT/scripts/tailscale-cleanup.sh" "$node" || true

    echo "--- Enabling PXE for $node ---"
    bash "$REPO_ROOT/scripts/pxe-control.sh" enable "$node"

    echo "--- Rebooting $node into PXE ---"
    if node_ssh_up "$node"; then
        echo "  SSH available"
        set_pxe_bootnext_via_ssh "$node"
        ssh_node "$node" sudo reboot || true
    else
        echo "  SSH not available — using kubectl"
        set_pxe_bootnext_via_kubectl "$node"
        reboot_via_kubectl "$node"
    fi

    wait_node_offline "$node" || true

    wait_ssh_up "$node"

    echo "--- Disabling PXE for $node ---"
    bash "$REPO_ROOT/scripts/pxe-control.sh" disable "$node"

    echo "--- Clearing stale known_hosts ---"
    ssh-keygen -R "$node" 2>/dev/null || true
    ssh-keygen -R "${NODE_IP[$node]}" 2>/dev/null || true

    echo "--- Verifying DHCP address ($node should have ${NODE_IP[$node]}) ---"
    actual_ip=$(ssh_node "$node" "ip -4 -br addr show ${NODE_NIC[$node]} | awk '{print \$3}' | cut -d/ -f1")
    if [[ "$actual_ip" != "${NODE_IP[$node]}" ]]; then
        echo "WARN: $node has IP $actual_ip, expected ${NODE_IP[$node]}."
        echo "WARN: MikroTik static lease may need manual reset — see CLAUDE.md."
    else
        echo "  IP correct: $actual_ip"
    fi

    echo "--- Rejoining k3s and installing Pelagos ---"
    bash "$REPO_ROOT/scripts/upgrade-agents.sh" "$node"

    wait_node_ready "$node"

    echo "--- Verifying Tailscale name is clean (single device, no -1 suffix) ---"
    bash "$REPO_ROOT/scripts/tailscale-cleanup.sh" --verify "$node" || true

    echo "--- Final check ---"
    ssh_ipc1 "sudo kubectl get node $node -o wide"
    echo "Done: $node"
done

echo ""
echo "=== Final cluster status ==="
ssh_ipc1 "sudo kubectl get nodes -o wide"
