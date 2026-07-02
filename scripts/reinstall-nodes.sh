#!/usr/bin/env bash
# PXE-reinstall one or more ipc worker nodes — hardened, preflight-gated.
#
# Flow:  PREFLIGHT (abort if any node can't be reimaged) -> deploy configs
#   per node:  cordon+drain -> clear known_hosts (driver+hub) -> arm PXE ->
#              one-shot BootNext -> reboot -> MONITOR (stall-aware) -> disable PXE
#              -> verify IP -> rejoin k3s+pelagos -> wait Ready -> uncordon ->
#              POSTFLIGHT (Ready + pelagos + cluster-deploy key + tailnet name)
#
# Boot model: nodes are DISK-FIRST; a one-shot `efibootmgr --bootnext <IPv4 PXE>`
# forces a single netboot, then reverts to disk automatically (normal reboots
# never stick at the netboot menu). The per-MAC iPXE file (.disabled gate) is
# armed/disarmed by pxe-control.sh.
#
# The monitor is STALL-AWARE: if a node sits in the installer (MikroTik lease
# host-name == "ubuntu-server") past STALL_WARN_MIN while the network is healthy,
# it flags a likely link/hardware stall instead of a blind 40-min wait. The known
# symptom is subiquity looping on "subiquity/Network/_send_update: CHANGE eno1"
# (eno1 link flapping during install; Intel I219-LM EEE/link quirks). Root cause
# is unconfirmed/intermittent, so this just makes it obvious and cheap to retry.
#
# Usage: reinstall-nodes.sh [--check] <node> [node...]
#   --check : PREFLIGHT ONLY (no changes) — fleet-readiness check.
# ipc1 is refused (control-plane; see docs/ipc1-upgrade-runbook.md).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/node-roles.sh"
source "$REPO_ROOT/scripts/lib/node-maps.sh"
SERVER="ipc1.taildd208.ts.net"
MIKROTIK="admin@192.168.88.1"
INSTALL_HARD_CAP_MIN=30      # hard timeout for install+first-boot
STALL_WARN_MIN=12           # flag a likely hardware hang if still installing past this
HUB_NODES=(ipc4 ipc5 ipc6)  # floating build nodes that reach every node via cluster-deploy

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && { CHECK_ONLY=1; shift; }
NODES=("$@")
[[ ${#NODES[@]} -eq 0 ]] && { echo "Usage: $0 [--check] <node> [node...]"; exit 1; }

for node in "${NODES[@]}"; do
    [[ "$node" == "ipc1" ]] && { echo "ERROR: ipc1 is the control plane — use docs/ipc1-upgrade-runbook.md" >&2; exit 1; }
    [[ -z "${NODE_IP[$node]+x}" ]] && { echo "ERROR: unknown node '$node' (see scripts/lib/node-maps.sh)" >&2; exit 1; }
done

ssh_ipc1()   { ssh -o StrictHostKeyChecking=no cb@"$SERVER" "$@"; }
ssh_node()   { local n=$1; shift; ssh -o StrictHostKeyChecking=no -J cb@"$SERVER" cb@"${NODE_IP[$n]}" "$@"; }
node_ssh_up(){ ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -J cb@"$SERVER" cb@"${NODE_IP[$1]}" true 2>/dev/null; }
kc()         { ssh_ipc1 "sudo kubectl $*"; }
ssh_mt()     { ssh -o StrictHostKeyChecking=no -J cb@"$SERVER" "$MIKROTIK" "$@"; }

# MikroTik lease host-name for a node's IP: "ubuntu-server"=installing, "<node>"=booted.
lease_hostname() { ssh_mt "/ip dhcp-server lease get [find where address=\"${NODE_IP[$1]}\"] host-name" 2>/dev/null | tr -d '\r'; }

# Emit a one-liner that finds the node's IPv4 PXE entry (by MAC, never IPv6/wrong NIC)
# and sets it as a ONE-SHOT BootNext. base64'd to dodge quoting across ssh.
bootnext_detect_script() {
    local macnc=$1
    printf '%s' "entry=\$(efibootmgr | grep -i 'MAC($macnc' | grep -i IPv4 | grep -oE '^Boot[0-9A-F]{4}' | grep -oE '[0-9A-F]{4}' | head -1); [ -n \"\$entry\" ] && efibootmgr --bootnext \"\$entry\" >/dev/null && echo \"BOOTNEXT=\$entry\" || echo BOOTNEXT=NONE"
}
set_pxe_bootnext_via_ssh() {
    local node=$1 macnc; macnc=$(mac_nocolon "$node")
    echo "--- Setting one-shot PXE BootNext on $node (IPv4 entry for ${NODE_MAC[$node]}) ---"
    local b64 out; b64=$(bootnext_detect_script "$macnc" | base64 -w0)
    out=$(ssh_node "$node" "echo $b64 | base64 -d | sudo -n sh" 2>/dev/null)
    echo "  $out"
    case "$out" in
        BOOTNEXT=NONE|"") echo "  ERROR: no IPv4 PXE entry for ${NODE_MAC[$node]} on $node" >&2; return 1 ;;
        BOOTNEXT=*) return 0 ;;
        *) echo "  ERROR: unexpected BootNext output on $node" >&2; return 1 ;;
    esac
}

clear_dynamic_leases() {
    local node=$1 mac="${NODE_MAC[$node]}"
    echo "--- Clearing dynamic MikroTik DHCP leases for $node ($mac) ---"
    ssh_mt "/ip dhcp-server lease remove [find where mac-address=\"$mac\" dynamic=yes]" 2>/dev/null \
        && echo "  cleared (or none)" || echo "  WARN: could not reach MikroTik"
}

# Clear a node's host key everywhere we connect FROM, BEFORE the reboot — so a
# re-imaged node's new key never deadlocks SSH detection (this bit us on ipc9).
clear_known_hosts() {
    local node=$1 ip="${NODE_IP[$node]}"
    echo "--- Clearing stale known_hosts for $node (driver + hub) ---"
    ssh-keygen -R "$node" 2>/dev/null || true
    ssh-keygen -R "$ip" 2>/dev/null || true
    for bn in "${HUB_NODES[@]}"; do
        [[ "$bn" == "$node" ]] && continue
        ssh_node "$bn" "ssh-keygen -R $node >/dev/null 2>&1; ssh-keygen -R $ip >/dev/null 2>&1" 2>/dev/null || true
    done
}

drain_node() {
    local node=$1
    echo "--- Cordon + drain $node (evict StatefulSets/pods before the wipe) ---"
    kc "cordon $node" || true
    kc "drain $node --ignore-daemonsets --delete-emptydir-data --timeout=150s" || \
        echo "  WARN: drain incomplete (continuing — node is being wiped anyway)"
}

wait_node_offline() {
    local node=$1 i=0
    echo "--- Waiting for $node to go offline (reboot; up to 10 min) ---"
    until ! node_ssh_up "$node"; do
        sleep 5; i=$((i+1)); [[ $i -gt 120 ]] && { echo "  WARN: $node never dropped SSH"; return 1; }
    done
    echo "  $node offline"
}

# Stall-aware install monitor. Returns 0 when the node's SSH is back (installed +
# booted), 1 on hard-cap timeout. Flags the hardware/carrier-change hang loudly.
wait_for_install() {
    local node=$1 start=$SECONDS warned=0
    echo "--- Monitoring $node install (hard cap ${INSTALL_HARD_CAP_MIN}m; stall warn at ${STALL_WARN_MIN}m) ---"
    echo "  (min 4 min before trusting SSH, to avoid a fast local-disk false positive)"
    sleep 240
    while (( (SECONDS - start)/60 < INSTALL_HARD_CAP_MIN )); do
        if node_ssh_up "$node"; then echo ""; echo "  $node SSH is up ($(( (SECONDS-start)/60 ))m)"; return 0; fi
        local mins hn; mins=$(( (SECONDS - start)/60 )); hn=$(lease_hostname "$node")
        if [[ "$hn" == "ubuntu-server" && $mins -ge $STALL_WARN_MIN && $warned -eq 0 ]]; then
            warned=1
            echo ""
            echo "  ============================================================"
            echo "  STALL WARNING: $node still in the installer at ${mins}m"
            echo "  Network/config are healthy (preflight passed), so this looks"
            echo "  like the known link stall: subiquity looping on"
            echo "  'subiquity/Network/_send_update: CHANGE eno1' (eno1 flapping)."
            echo "  NOT the pipeline; cause intermittent/unconfirmed."
            echo "  ACTION: check $node console; power-cycle and/or reseat the NET"
            echo "  cable, then it retries automatically on next boot (PXE stays armed)."
            echo "  ============================================================"
        fi
        printf "  installing... (%dm, lease host-name=%s)\r" "$mins" "${hn:-?}"
        sleep 30
    done
    echo ""
    echo "ERROR: $node not back within ${INSTALL_HARD_CAP_MIN}m (last host-name='$(lease_hostname "$node")')." >&2
    [[ "$(lease_hostname "$node")" == "ubuntu-server" ]] && \
        echo "       Stuck in the installer → almost certainly the hardware/carrier-change hang. Power-cycle and retry." >&2
    return 1
}

wait_node_ready() {
    local node=$1 i=0
    echo "--- Waiting for $node Ready in kubectl (up to 5 min) ---"
    until kc "get node $node --no-headers" 2>/dev/null | grep -qw Ready; do
        sleep 15; i=$((i+1)); [[ $i -gt 20 ]] && { echo "ERROR: $node not Ready after 5 min" >&2; return 1; }
    done
    echo "  $node Ready"
}

postflight() {
    local node=$1 fail=0
    echo "--- Postflight: $node ---"
    if kc "get node $node --no-headers" 2>/dev/null | grep -qw Ready; then echo "  [OK] node Ready"; else echo "  [FAIL] node not Ready"; fail=1; fi
    if kc "get node $node -o jsonpath={.spec.unschedulable}" 2>/dev/null | grep -q true; then echo "  [FAIL] still cordoned"; fail=1; else echo "  [OK] schedulable (uncordoned)"; fi
    local ver; ver=$(ssh_node "$node" "pelagos --version 2>/dev/null" | awk '{print $2}')
    if [[ -n "$ver" ]]; then echo "  [OK] pelagos $ver"; else echo "  [FAIL] pelagos not installed"; fail=1; fi
    # Prove the PXE-provisioned cluster-deploy key works: a hub node reaches this node with it.
    # Clear the hub's stale entry first — the reimaged node has a NEW host key, and
    # accept-new won't override a CHANGED one (else this false-WARNs, as on ipc7).
    # Connect by LAN IP (the path the build hub actually delivers over) — the
    # hostname resolves via Tailscale MagicDNS on the hub, which churns a
    # different host key than the LAN one after the node re-enrolls.
    ssh_node ipc4 "ssh-keygen -R ${NODE_IP[$node]} >/dev/null 2>&1" 2>/dev/null || true
    if ssh_node ipc4 "ssh -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/cluster-deploy -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 cb@${NODE_IP[$node]} true" 2>/dev/null; then
        echo "  [OK] cluster-deploy key: ipc4 -> $node"
    else echo "  [WARN] cluster-deploy key path ipc4 -> $node not working"; fi
    return $fail
}

# ---------------------------------------------------------------------------
echo "=== PXE Reinstall: ${NODES[*]} ==="

echo ""
echo "### PREFLIGHT ###"
if ! bash "$REPO_ROOT/scripts/pxe-preflight.sh" "${NODES[@]}"; then
    echo "ABORT: preflight failed — nothing was changed. Fix the above and retry." >&2
    exit 1
fi
if [[ $CHECK_ONLY -eq 1 ]]; then echo "--check: preflight only, exiting."; exit 0; fi

echo ""
echo "### DEPLOY CONFIGS ###"
bash "$REPO_ROOT/scripts/deploy-pxe-configs.sh"

rc=0
for node in "${NODES[@]}"; do
    echo ""
    echo "====== $node ======"
    drain_node "$node"
    clear_dynamic_leases "$node"
    echo "--- Removing stale Tailscale device for $node (reclaim its name) ---"
    bash "$REPO_ROOT/scripts/tailscale-cleanup.sh" "$node" || true
    clear_known_hosts "$node"

    echo "--- Arming PXE for $node ---"
    bash "$REPO_ROOT/scripts/pxe-control.sh" enable "$node"

    if ! node_ssh_up "$node"; then
        echo "ERROR: $node not reachable to set BootNext — aborting $node (preflight should have caught this)." >&2
        rc=1; continue
    fi
    if ! set_pxe_bootnext_via_ssh "$node"; then
        echo "ERROR: could not set BootNext on $node — aborting $node (disk-first won't PXE)." >&2
        bash "$REPO_ROOT/scripts/pxe-control.sh" disable "$node" || true
        rc=1; continue
    fi
    echo "--- Rebooting $node into the one-shot PXE install ---"
    ssh_node "$node" sudo reboot || true

    wait_node_offline "$node" || true
    if ! wait_for_install "$node"; then
        echo "ERROR: $node install did not complete — leaving PXE armed for a retry after you power-cycle it." >&2
        rc=1; continue
    fi

    echo "--- Disabling PXE for $node ---"
    bash "$REPO_ROOT/scripts/pxe-control.sh" disable "$node"

    echo "--- Verifying DHCP address ($node -> ${NODE_IP[$node]}) ---"
    actual=$(ssh_node "$node" "ip -4 -br addr show ${NODE_NIC[$node]} | awk '{print \$3}' | cut -d/ -f1" 2>/dev/null)
    [[ "$actual" == "${NODE_IP[$node]}" ]] && echo "  IP correct: $actual" || echo "  WARN: $node has '$actual', expected ${NODE_IP[$node]}"

    echo "--- Rejoining k3s + installing pelagos (role: $(k3s_role "$node")) ---"
    if is_server_node "$node"; then bash "$REPO_ROOT/scripts/join-server.sh" "$node"
    else bash "$REPO_ROOT/scripts/upgrade-agents.sh" "$node"; fi

    wait_node_ready "$node" || rc=1
    echo "--- Uncordoning $node ---"
    kc "uncordon $node" || true

    echo "--- Verifying Tailscale name is clean ---"
    bash "$REPO_ROOT/scripts/tailscale-cleanup.sh" --verify "$node" || true

    postflight "$node" || { echo "  postflight found issues on $node"; rc=1; }
    echo "Done: $node"
done

echo ""
echo "=== Final cluster status ==="
kc "get nodes -o wide" || true
[[ $rc -eq 0 ]] && echo "=== ALL NODES OK ===" || echo "=== COMPLETED WITH ISSUES (rc=$rc) — see above ==="
exit $rc
