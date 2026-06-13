#!/usr/bin/env bash
# Restore the ipc1 control plane onto a FRESH Ubuntu 26.04 install from a
# backup-ipc1.sh tarball. Brings the cluster back with the SAME CA, node token
# and IP, so every agent reconnects with no re-trust.
#
# Preconditions:
#   - ipc1 freshly installed (26.04), reachable, cb key-auth working, on its
#     normal IP (192.168.88.53) — agents are pinned to https://192.168.88.53:6443.
#   - You have a verified backup tarball (from backup-ipc1.sh) on omen.
#
# Order matters: Pelagos (CRI) must be running before k3s starts, and the
# restored datastore/certs must overwrite the fresh install BEFORE first start.
#
# Run from omen. Usage: ./restore-ipc1.sh <backup.tar.gz> [k3s-version]
set -euo pipefail

IPC1="cb@ipc1.taildd208.ts.net"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP="${1:?usage: restore-ipc1.sh <backup.tar.gz> [k3s-version]}"
K3S_VERSION="${2:-v1.35.5+k3s1}"   # MUST match the version that took the backup
[[ -f "$BACKUP" ]] || { echo "ERROR: backup not found: $BACKUP" >&2; exit 1; }

ssh1() { ssh -o StrictHostKeyChecking=no "$IPC1" "$@"; }

echo "=== Restore ipc1 control plane from $(basename "$BACKUP") (k3s $K3S_VERSION) ==="

echo "--- sanity: ipc1 is fresh 26.04, reachable, right IP ---"
ssh1 "lsb_release -ds; ip -4 -br addr show | grep -q 192.168.88.53 && echo 'IP ok: 192.168.88.53' || { echo 'ERROR: ipc1 is not on 192.168.88.53'; exit 1; }"
ssh1 "test ! -e /var/lib/rancher/k3s/server/db && echo 'fresh (no existing datastore) — good' || echo 'WARN: a datastore already exists; it will be replaced'"

echo "--- copy backup to ipc1 ---"
scp -o StrictHostKeyChecking=no "$BACKUP" "$IPC1:/tmp/ipc1-restore.tar.gz"

echo "--- restore /etc/rancher/k3s (server config) BEFORE install ---"
ssh1 "sudo tar -xzf /tmp/ipc1-restore.tar.gz -C / etc/rancher/k3s"

echo "--- install Pelagos CRI (must run before k3s starts) ---"
# install-pelagos ends with `systemctl restart k3s`, which fails on a fresh node
# (k3s isn't installed yet) and would abort us under set -e. Tolerate that exit,
# then ASSERT pelagos-cri actually came up — so a real Pelagos failure still stops
# the restore (rather than silently swallowing it).
bash "$REPO_ROOT/scripts/install-pelagos.sh" ipc1 || true
ssh1 "systemctl is-active --quiet pelagos-cri" || { echo "ERROR: pelagos-cri is not active on ipc1 — aborting restore" >&2; exit 1; }
echo "  pelagos-cri active"

echo "--- install k3s ${K3S_VERSION} server WITHOUT starting it ---"
ssh1 "curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION='${K3S_VERSION}' INSTALL_K3S_SKIP_START=true sh -s - server"

echo "--- replace the fresh datastore/certs/token with the backed-up originals ---"
ssh1 "sudo systemctl stop k3s 2>/dev/null || true; sudo rm -rf /var/lib/rancher/k3s/server && sudo tar -xzf /tmp/ipc1-restore.tar.gz -C / var/lib/rancher/k3s/server"

echo "--- start k3s with the restored state ---"
ssh1 "sudo systemctl enable --now k3s"

echo "--- wait for the API to answer (up to 3 min) ---"
ssh1 'i=0; until sudo k3s kubectl get --raw=/readyz >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 36 ] && { echo "ERROR: API not ready after 3 min"; exit 1; }; sleep 5; done; echo "API ready"'

echo "--- VALIDATION GATES ---"
ssh1 "rm -f /tmp/ipc1-restore.tar.gz"
echo "  nodes (expect all 6 Ready, same identities):"
ssh1 "sudo kubectl get nodes -o wide --no-headers | awk '{print \"    \"\$1,\$2,\$5,\$8}'"
echo "  agent TLS errors in last 200 k3s log lines (expect none):"
ssh1 "sudo journalctl -u k3s --no-pager -n 200 | grep -iE 'x509|certificate|tls handshake' | tail -5 || echo '    none'"
echo "  Flux kustomizations:"
ssh1 "sudo kubectl get kustomizations -A --no-headers 2>/dev/null | awk '{print \"    \"\$1,\$2,\$3}' || echo '    (flux not queryable yet)'"
echo "  schedulable test (throwaway pod):"
ssh1 "sudo kubectl run restore-check --image=busybox --restart=Never --rm -i --command -- echo cluster-ok 2>/dev/null | tail -1 || echo '    test pod did not run — investigate'"

echo "=== restore done. Then: install-nut-clients.sh ipc1, tailscale-cleanup.sh --verify ipc1. ==="
echo "    If any gate failed: re-restore from backup, or fall back to Flux re-reconcile from Git."
