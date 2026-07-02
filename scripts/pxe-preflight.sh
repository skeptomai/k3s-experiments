#!/usr/bin/env bash
# Preflight for a PXE reinstall: validate a node CAN actually be reimaged BEFORE
# rebooting it into a disk wipe. Read-only — safe to run anytime (also good as a
# fleet-readiness check). reinstall-nodes.sh runs this first and aborts if it fails.
#
# Catches the failure classes that turned the ipc9 canary into a slog:
#   - pxe-control / menu file missing for the node
#   - autoinstall config not servable by nginx (0744 dir → 403 → silent stall)
#   - no IPv4 PXE boot entry on the node (BootNext can't target it)
#   - node unreachable to set BootNext
#   - non-deterministic DHCP (no static lease)
#   - Tailscale cleanup credential absent (device won't be reclaimed) [warn]
#
# Usage: pxe-preflight.sh <node> [node...]
# Exit: 0 = all pass; 1 = at least one hard check failed.
set -uo pipefail   # deliberately NOT -e: run every check, report all findings

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/node-maps.sh"
SERVER="ipc1.taildd208.ts.net"
MIKROTIK="admin@192.168.88.1"
NB="http://192.168.89.2:31011"                                   # nazgul netboot assets
MENUS="/mnt/.ix-apps/app_mounts/netbootxyz/config/menus"
TS_CRED="/mnt/primary_storage/tailscale-cleanup-cred"           # on nazgul

fails=0; warns=0
ok()   { echo "  [ OK ] $*"; }
bad()  { echo "  [FAIL] $*"; fails=$((fails+1)); }
warn() { echo "  [WARN] $*"; warns=$((warns+1)); }

ssh_ipc1() { ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no cb@"$SERVER" "$@"; }
ssh_node() { ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -J cb@"$SERVER" cb@"$1" "${@:2}"; }
ssh_naz()  { ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no root@nazgul "$@"; }
ssh_mt()   { ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -J cb@"$SERVER" "$MIKROTIK" "$@"; }

[[ $# -eq 0 ]] && { echo "usage: $0 <node> [node...]"; exit 2; }

for node in "$@"; do
  echo "== preflight: $node =="
  if [[ -z "${NODE_MAC[$node]+x}" ]]; then bad "unknown node (not in node-maps.sh)"; continue; fi
  if [[ "$node" == "ipc1" ]]; then bad "ipc1 is control-plane — not reinstallable via this path"; continue; fi
  macnc=$(mac_nocolon "$node"); macd=$(mac_dashed "$node"); ip="${NODE_IP[$node]}"

  # 1. per-MAC iPXE menu file present on nazgul (enabled or .disabled)
  if ssh_naz "ls ${MENUS}/MAC-${macnc}.ipxe ${MENUS}/MAC-${macnc}.ipxe.disabled 2>/dev/null | grep -q ."; then
    ok "iPXE menu file present (pxe-control can arm it)"
  else
    bad "no iPXE menu file MAC-${macnc}.ipxe[.disabled] on nazgul — run deploy-pxe-configs.sh"
  fi

  # 2. THE big one: autoinstall config actually SERVES 200 (not 403 from a 0744 dir)
  for f in user-data meta-data; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "$NB/autoinstall/$macd/$f" 2>/dev/null)
    if [[ "$code" == 200 ]]; then ok "autoinstall/$macd/$f serves 200"
    else bad "autoinstall/$macd/$f serves '$code' — cloud-init will stall (check dir perms 0755)"; fi
  done

  # 3. node reachable to set BootNext (must be up pre-reboot)
  if ssh_node "$ip" true 2>/dev/null; then ok "node reachable via SSH (can set BootNext)"
  else bad "node not reachable via SSH — can't set one-shot BootNext (disk-first won't PXE)"; fi

  # 4. node has an IPv4 PXE boot entry matching its MAC (BootNext target exists)
  if ssh_node "$ip" "sudo efibootmgr 2>/dev/null | grep -i 'MAC($macnc' | grep -qi IPv4" 2>/dev/null; then
    ok "IPv4 PXE boot entry present (BootNext can target it)"
  else
    bad "no IPv4 PXE boot entry for $macnc — enable 'Network Boot' in BIOS (one-time)"
  fi

  # 5. deterministic IP: a static (dynamic=false) MikroTik lease for this address
  if ssh_mt "/ip dhcp-server lease print count-only where address=$ip dynamic=no" 2>/dev/null | grep -q '^1'; then
    ok "static DHCP lease reserves $ip (deterministic on reinstall)"
  else
    warn "no static lease for $ip — node may not reclaim its IP after reinstall"
  fi
done

# 6. Tailscale cleanup credential (shared, not per-node) — warn only
if ssh_naz "test -s $TS_CRED" 2>/dev/null; then
  echo "== shared =="; ok "Tailscale cleanup credential present on nazgul ($TS_CRED)"
else
  echo "== shared =="; warn "no Tailscale cleanup credential ($TS_CRED) — stale devices won't be auto-removed"
fi

echo ""
if [[ $fails -gt 0 ]]; then
  echo "PREFLIGHT FAIL: $fails hard failure(s), $warns warning(s) — do NOT reinstall until fixed."
  exit 1
fi
echo "PREFLIGHT PASS ($warns warning(s))."
