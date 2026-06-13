#!/usr/bin/env bash
# Back up the ipc1 k3s control-plane state ("crown jewels") before an OS upgrade.
#
# ipc1 is a single-server k3s with a SQLite datastore; the cluster's entire
# state (deployments, secrets, PV bindings, SPIRE registrations, ...) plus the
# CA certs + node token live ONLY on ipc1. This captures all of it so the
# cluster can be restored onto a fresh install (restore-ipc1.sh) OR recovered if
# an in-place dist-upgrade goes wrong.
#
# Briefly STOPS k3s for a consistent datastore copy (~30s control-plane blip;
# existing pods on workers keep running), then restarts it — safe + repeatable.
# Run it right before the upgrade to minimise drift.
#
# Run from omen (or anywhere with tailnet SSH to ipc1). Uses the tailnet
# hostname + ipc1-jump to nazgul, so it works off-LAN.
#
# !! The backup contains the CA PRIVATE KEY + node token. It's written 0600 and
#    kept in root-only dirs. Treat it like a secret; never commit it.
#
# Usage: ./backup-ipc1.sh [label]   (label defaults to a plain "manual" tag;
#        pass a timestamp from the caller since scripts can't read the clock)
set -euo pipefail

IPC1="cb@ipc1.taildd208.ts.net"
LABEL="${1:-manual}"
NAME="ipc1-k3s-backup-${LABEL}.tar.gz"
LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)/backups"
NAZGUL_DIR="/mnt/primary_storage/backups"

ssh1() { ssh -o StrictHostKeyChecking=no "$IPC1" "$@"; }

echo "=== ipc1 control-plane backup: ${NAME} ==="

echo "--- recording k3s version + server config ---"
ssh1 "k3s --version | head -1; echo '--- /etc/rancher/k3s/config.yaml ---'; sudo cat /etc/rancher/k3s/config.yaml" \
    | tee "/tmp/ipc1-k3s-meta-${LABEL}.txt"

echo "--- stopping k3s for a consistent copy ---"
ssh1 "sudo systemctl stop k3s"

echo "--- tarring /var/lib/rancher/k3s/server + /etc/rancher/k3s ---"
ssh1 "sudo tar -czf /tmp/${NAME} -C / var/lib/rancher/k3s/server etc/rancher/k3s && sudo sha256sum /tmp/${NAME}"

echo "--- restarting k3s (cluster control plane back up) ---"
ssh1 "sudo systemctl start k3s"

echo "--- pulling to omen: ${LOCAL_DIR} ---"
mkdir -p "$LOCAL_DIR" && chmod 700 "$LOCAL_DIR"
ssh1 "sudo chown cb /tmp/${NAME} && chmod 600 /tmp/${NAME}"
scp -o StrictHostKeyChecking=no "$IPC1:/tmp/${NAME}" "$LOCAL_DIR/${NAME}"
chmod 600 "$LOCAL_DIR/${NAME}"
ssh1 "rm -f /tmp/${NAME}"

echo "--- copying to nazgul: ${NAZGUL_DIR} (root-only) ---"
ssh -o StrictHostKeyChecking=no -J "$IPC1" root@192.168.89.2 "mkdir -p ${NAZGUL_DIR} && chmod 700 ${NAZGUL_DIR}"
scp -o StrictHostKeyChecking=no -J "$IPC1" "$LOCAL_DIR/${NAME}" "root@192.168.89.2:${NAZGUL_DIR}/${NAME}"
ssh -o StrictHostKeyChecking=no -J "$IPC1" root@192.168.89.2 "chmod 600 ${NAZGUL_DIR}/${NAME}"

echo "--- verifying the tarball lists the crown jewels ---"
echo "  contents (expected: server/{db,tls,token,cred}, etc/rancher/k3s):"
tar -tzf "$LOCAL_DIR/${NAME}" | grep -E 'server/(db|tls|token|cred)|etc/rancher/k3s/config.yaml' | sed 's/^/    /' | sort -u | head -20
echo "  local sha256: $(sha256sum "$LOCAL_DIR/${NAME}" | awk '{print $1}')"
echo "  omen copy:    $LOCAL_DIR/${NAME}"
echo "  nazgul copy:  ${NAZGUL_DIR}/${NAME}"
echo "=== backup complete. VERIFY the contents above include db/ + tls/ + token before reinstalling. ==="

# Optional encryption (recommended, since the backup holds the CA key):
#   age -r <recipient> "$LOCAL_DIR/${NAME}" > "$LOCAL_DIR/${NAME}.age" && shred -u "$LOCAL_DIR/${NAME}"
# (left manual/commented — wire up an age recipient or gpg key if desired.)
