#!/usr/bin/env bash
# Rebuild a k3s control-plane SEED from an etcd snapshot.
#
# This is the disaster-recovery / control-plane-migration primitive: it turns any
# reachable node into the SOLE etcd member of the cluster, populated from a
# snapshot. Afterward you rejoin the other servers/agents (join-server.sh /
# install-pelagos.sh) pointed at this seed (or the kube-vip VIP).
#
# Derived from the LIVE cluster (observed 2026-07-04):
#   - k3s v1.35.5+k3s1, installed via get.k3s.io, config-driven (/etc/rancher/k3s/config.yaml)
#   - container runtime = pelagos CRI (must be running; k3s config points at its socket)
#   - server config template: config/k3s-server.yaml (cluster-init, tls-san VIP)
#   - the snapshot's CA + secrets-encryption are bound to the ORIGINAL server token,
#     so we install with that token BEFORE the restore, or the restored state won't decrypt.
#
# Usage:
#   scripts/restore-cluster.sh <seed-node> <snapshot-file> <token-file>
#     seed-node     : node to become the restored sole server (e.g. ipc4)
#     snapshot-file : local path to the etcd snapshot (e.g. from nazgul backup)
#     token-file    : local path to the ORIGINAL cluster server token
#
# Safe to run while the OLD cluster is still up (this seed becomes an ISOLATED
# single-member cluster from the snapshot; it does NOT touch the old etcd). Keep the
# old control-plane running as rollback until this seed is verified healthy. Do NOT
# apply kube-vip here — bring the VIP up only after the old CP nodes are stopped, to
# avoid two clusters fighting over the same VIP.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/node-roles.sh"
source "$REPO_ROOT/scripts/lib/node-maps.sh"

SEED="${1:?usage: restore-cluster.sh <seed-node> <snapshot-file> <token-file>}"
SNAP_LOCAL="${2:?snapshot file}"
TOKEN_LOCAL="${3:?token file}"
VER="${K3S_VERSION:-v1.35.5+k3s1}"

[[ -n "${NODE_IP[$SEED]:-}" ]] || { echo "ERROR: unknown node '$SEED'" >&2; exit 1; }
[[ -f "$SNAP_LOCAL"  ]] || { echo "ERROR: snapshot '$SNAP_LOCAL' not found" >&2; exit 1; }
[[ -f "$TOKEN_LOCAL" ]] || { echo "ERROR: token file '$TOKEN_LOCAL' not found" >&2; exit 1; }

IP="${NODE_IP[$SEED]}"
SSH() { ssh -o StrictHostKeyChecking=no "cb@$SEED" "$@"; }   # tailnet name via ~/.ssh/config

echo "=== restore-cluster: seed=$SEED ($IP)  k3s=$VER  snapshot=$(basename "$SNAP_LOCAL") ==="

echo "--- [1/6] preflight: pelagos-cri must be running (k3s config points at its socket) ---"
SSH 'sudo systemctl is-active pelagos-cri >/dev/null 2>&1' \
  || { echo "ERROR: pelagos-cri not active on $SEED — run scripts/install-pelagos.sh $SEED first" >&2; exit 1; }

echo "--- [2/6] copy snapshot + original token to $SEED (/root/restore, root-only) ---"
SSH 'sudo mkdir -p /root/restore && sudo chmod 700 /root/restore'
# shellcheck disable=SC2002
cat "$SNAP_LOCAL"  | SSH 'sudo tee /root/restore/snapshot >/dev/null'
cat "$TOKEN_LOCAL" | SSH 'sudo tee /root/restore/token >/dev/null && sudo chmod 600 /root/restore/token /root/restore/snapshot'
SSH 'echo "  snapshot bytes: $(sudo stat -c %s /root/restore/snapshot); token bytes: $(sudo wc -c < /root/restore/token)"'

echo "--- [3/6] uninstall any existing k3s/k3s-agent on $SEED (keeps /var/lib/vault-data, /opt/local-path) ---"
SSH 'if [ -x /usr/local/bin/k3s-uninstall.sh ]; then sudo /usr/local/bin/k3s-uninstall.sh; \
     elif [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then sudo /usr/local/bin/k3s-agent-uninstall.sh; \
     else echo "  (no prior k3s install)"; fi'

echo "--- [4/6] write SEED server config (cluster-init) with the ORIGINAL token injected ---"
# strip comments from the template, then append the token line so the restored
# token-bound bootstrap decrypts after cluster-reset.
TOKEN_VAL="$(cat "$TOKEN_LOCAL")"
{ grep -vE '^\s*#' "$REPO_ROOT/config/k3s-server.yaml"; printf 'token: "%s"\n' "$TOKEN_VAL"; } \
  | SSH 'sudo mkdir -p /etc/rancher/k3s && sudo tee /etc/rancher/k3s/config.yaml >/dev/null && sudo chmod 600 /etc/rancher/k3s/config.yaml'
SSH 'echo "  config written (cluster-init: $(sudo grep -c "^cluster-init:" /etc/rancher/k3s/config.yaml), token line: $(sudo grep -c "^token:" /etc/rancher/k3s/config.yaml))"'

echo "--- [5/6] install k3s SERVER (fresh cluster-init etcd), wait for API ---"
SSH "curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION='$VER' INSTALL_K3S_EXEC=server sh -"
SSH 'for i in $(seq 1 60); do sudo k3s kubectl get --raw=/readyz >/dev/null 2>&1 && { echo "  API ready"; break; }; sleep 3; done'

echo "--- [6/6] RESTORE snapshot: stop k3s -> cluster-reset-restore -> start ---"
SSH 'sudo systemctl stop k3s'
SSH 'sudo k3s server --cluster-reset --cluster-reset-restore-path=/root/restore/snapshot 2>&1 | tail -20'
SSH 'sudo systemctl start k3s'
SSH 'for i in $(seq 1 90); do sudo k3s kubectl get --raw=/readyz >/dev/null 2>&1 && { echo "  API ready after restore"; break; }; sleep 3; done'

echo
echo "=== RESTORE COMPLETE on $SEED. Cluster state (from snapshot) — old nodes still listed: ==="
SSH 'sudo k3s kubectl get nodes -o wide 2>/dev/null'
cat <<EOF

Next (only after verifying $SEED holds the expected restored state):
  1. Delete stale node objects: ssh $SEED 'sudo k3s kubectl delete node <old-nodes>'
  2. STOP the old control-plane nodes (releases the VIP), then apply the eno1 kube-vip:
       sudo k3s kubectl apply -f manifests/kube-vip/
  3. Rejoin servers:  scripts/join-server.sh <node>   (points at the VIP)
     Rejoin agents:   scripts/install-agent.sh <node>  (points at the VIP)
EOF
