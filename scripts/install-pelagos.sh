#!/usr/bin/env bash
# Installs or upgrades Pelagos CRI on one or more ipc nodes.
# Run from any machine with SSH access to ipc4 via the tailnet.
# ipc5 and ipc6 are reached by jumping through ipc4.
#
# Installs the latest pelagos release deb (which includes both pelagos and
# pelagos-cri), sets up /usr/local/bin symlinks, writes the pelagos-cri
# systemd unit, and deploys the canonical k3s config from config/k3s-server.yaml
# or config/k3s-agent.yaml in the repo root. Safe to run multiple times (idempotent).
#
# Role-aware: deploys the server config (k3s-server.yaml on the etcd seed ipc4,
# k3s-server-join.yaml with the token injected on ipc5/ipc6) + the `k3s` unit on
# control-plane nodes, and the agent config + `k3s-agent` unit on workers ipc7-9.
# Role map: scripts/lib/node-roles.sh.
#
# Usage: ./install-pelagos.sh [--version vX.Y.Z] [node...]
#   --version: pin a specific release (default: latest)
#   node: ipc4 | ipc5 | ipc6 | ipc7 | ipc8 | ipc9 (default: all six)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="ipc4.taildd208.ts.net"
source "$REPO_ROOT/scripts/lib/node-roles.sh"
DEFAULT_NODES=(ipc4 ipc5 ipc6 ipc7 ipc8 ipc9)
declare -A NODE_IP=([ipc4]="" [ipc5]="192.168.88.56" [ipc6]="192.168.88.57" [ipc7]="192.168.88.63" [ipc8]="192.168.88.64" [ipc9]="192.168.88.65")

VERSION_PIN=""
NODES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION_PIN="$2"; shift 2 ;;
        *) NODES+=("$1"); shift ;;
    esac
done
[[ ${#NODES[@]} -eq 0 ]] && NODES=("${DEFAULT_NODES[@]}")

# If any JOINING control-plane server (a server node other than the etcd seed) is
# targeted, fetch the live server token from the seed to inject into its join
# config. The token is a secret and is never stored in the repo config file.
SERVER_TOKEN=""
for n in "${NODES[@]}"; do
    if is_server_node "$n" && [[ "$n" != "$CLUSTER_INIT_NODE" ]]; then
        echo "=== Fetching server token from $CLUSTER_INIT_NODE (for joining servers) ==="
        SERVER_TOKEN=$(ssh -o StrictHostKeyChecking=no cb@"$SERVER" \
            "sudo cat /var/lib/rancher/k3s/server/token")
        break
    fi
done

echo "=== Fetching Pelagos release ==="
if [[ -n "$VERSION_PIN" ]]; then
    LATEST="$VERSION_PIN"
else
    LATEST=$(gh release list --repo pelagos-containers/pelagos --limit 1 --json tagName --jq '.[0].tagName')
fi
DEB_URL=$(gh release view "$LATEST" --repo pelagos-containers/pelagos --json assets \
    --jq '.assets[] | select(.name | test("amd64[.]deb")) | .url')
echo "Version: $LATEST  deb: $DEB_URL"

install_node() {
    local node=$1
    local ssh_cmd svc k3s_config_b64 registries_b64

    if [ "$node" = "ipc4" ]; then
        ssh_cmd="ssh -o StrictHostKeyChecking=no cb@$SERVER"
    else
        ssh_cmd="ssh -o StrictHostKeyChecking=no -J cb@$SERVER cb@${NODE_IP[$node]}"
    fi
    svc=$(k3s_service "$node")

    # Role-aware k3s config:
    #   - etcd seed (ipc4)        -> server config (cluster-init)
    #   - joining server (ipc5/6) -> server-join config, token injected
    #   - agent (ipc7-9)          -> agent config
    if [ "$node" = "$CLUSTER_INIT_NODE" ]; then
        k3s_config_b64=$(base64 -w0 < "$REPO_ROOT/config/k3s-server.yaml")
    elif is_server_node "$node"; then
        [[ -n "$SERVER_TOKEN" ]] || { echo "ERROR: server token not fetched for $node" >&2; return 1; }
        # Match either placeholder name (IPC1 on master / SEED on the migration branch).
        k3s_config_b64=$(sed -E "s|<INJECTED_AT_INSTALL_FROM_[A-Z0-9]+_TOKEN>|${SERVER_TOKEN}|" \
            "$REPO_ROOT/config/k3s-server-join.yaml" | base64 -w0)
    else
        k3s_config_b64=$(base64 -w0 < "$REPO_ROOT/config/k3s-agent.yaml")
    fi
    registries_b64=$(base64 -w0 < "$REPO_ROOT/config/pelagos-registries.toml")

    echo ""
    echo "=== Installing Pelagos $LATEST on $node ==="

    $ssh_cmd bash -s "$DEB_URL" "$svc" "$k3s_config_b64" "$registries_b64" <<'REMOTE'
set -euo pipefail
DEB_URL=$1
K3S_SERVICE=$2
K3S_CONFIG=$(echo "$3" | base64 -d)
REGISTRIES_CONFIG=$(echo "$4" | base64 -d)

echo "--- Installing deb ---"
curl -sL "$DEB_URL" -o /tmp/pelagos.deb
# dpkg -i unpacks but does NOT resolve/configure dependencies — on a fresh base OS
# it leaves the package "unconfigured". ALWAYS run `apt-get install -f` afterwards to
# configure it (and pull any missing dep), then verify. (Piping dpkg to `tail` masks
# its exit code, so the old `|| apt-get` fallback never fired — hence always run it.)
sudo dpkg -i /tmp/pelagos.deb 2>&1 | tail -5 || true
sudo apt-get install -f -y 2>&1 | tail -5
dpkg -l pelagos 2>/dev/null | grep -q "^ii" || { echo "ERROR: pelagos deb failed to configure"; exit 1; }

echo "--- Symlinking binaries ---"
sudo ln -sf /usr/bin/pelagos /usr/local/bin/pelagos
sudo ln -sf /usr/bin/pelagos-cri /usr/local/bin/pelagos-cri

echo "--- Writing systemd unit ---"
sudo tee /etc/systemd/system/pelagos-cri.service >/dev/null <<UNIT
[Unit]
Description=Pelagos CRI gRPC server
Documentation=https://github.com/pelagos-containers/pelagos
After=network.target
Before=${K3S_SERVICE}.service

[Service]
Type=simple
ExecStartPre=/usr/bin/mkdir -p /run/pelagos
ExecStart=/usr/local/bin/pelagos-cri --pelagos-bin /usr/local/bin/pelagos --socket /run/pelagos/cri.sock
Restart=always
RestartSec=5s
Environment=RUST_LOG=info
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

echo "--- Deploying k3s config ---"
sudo mkdir -p /etc/rancher/k3s
echo "$K3S_CONFIG" | sudo tee /etc/rancher/k3s/config.yaml >/dev/null
echo "Config written:"
sudo cat /etc/rancher/k3s/config.yaml

echo "--- Deploying Pelagos registry mirror config ---"
sudo mkdir -p /etc/pelagos
echo "$REGISTRIES_CONFIG" | sudo tee /etc/pelagos/registries.toml >/dev/null
echo "Registries config written:"
sudo cat /etc/pelagos/registries.toml

echo "--- Stopping $K3S_SERVICE before CRI restart (prevents container process orphaning) ---"
sudo systemctl stop "$K3S_SERVICE" || true
sleep 3

echo "--- Enabling and starting pelagos-cri ---"
sudo systemctl daemon-reload
sudo systemctl enable pelagos-cri
sudo systemctl restart pelagos-cri
sleep 5
sudo systemctl is-active pelagos-cri

echo "--- Starting $K3S_SERVICE ---"
sudo systemctl start "$K3S_SERVICE"

pelagos --version
echo "Done"
REMOTE

    echo "Done: $node"
}

for node in "${NODES[@]}"; do
    install_node "$node"
done

echo ""
echo "=== Node status ==="
sleep 10
ssh -o StrictHostKeyChecking=no cb@"$SERVER" "sudo kubectl get nodes -o wide"
