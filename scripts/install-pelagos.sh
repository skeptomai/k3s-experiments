#!/usr/bin/env bash
# Installs or upgrades Pelagos CRI on one or more ipc nodes.
# Run from any machine with SSH access to ipc1 via the tailnet.
# ipc2 and ipc3 are reached by jumping through ipc1.
#
# Installs the latest pelagos release deb (which includes both pelagos and
# pelagos-cri), sets up /usr/local/bin symlinks, writes the pelagos-cri
# systemd unit, and deploys the canonical k3s config from config/k3s-server.yaml
# or config/k3s-agent.yaml in the repo root. Safe to run multiple times (idempotent).
#
# Usage: ./install-pelagos.sh [--version vX.Y.Z] [node...]
#   --version: pin a specific release (default: latest)
#   node: ipc1 | ipc2 | ipc3 (default: ipc1 ipc2 ipc3)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="ipc1.taildd208.ts.net"
DEFAULT_NODES=(ipc1 ipc2 ipc3)

VERSION_PIN=""
NODES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION_PIN="$2"; shift 2 ;;
        *) NODES+=("$1"); shift ;;
    esac
done
[[ ${#NODES[@]} -eq 0 ]] && NODES=("${DEFAULT_NODES[@]}")

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
    local ssh_cmd k3s_service k3s_config_b64

    if [ "$node" = "ipc1" ]; then
        ssh_cmd="ssh -o StrictHostKeyChecking=no cb@$SERVER"
        k3s_service="k3s"
        k3s_config_b64=$(base64 -w0 < "$REPO_ROOT/config/k3s-server.yaml")
    else
        ssh_cmd="ssh -o StrictHostKeyChecking=no -J cb@$SERVER cb@$node"
        k3s_service="k3s-agent"
        k3s_config_b64=$(base64 -w0 < "$REPO_ROOT/config/k3s-agent.yaml")
    fi

    echo ""
    echo "=== Installing Pelagos $LATEST on $node ==="

    $ssh_cmd bash -s "$DEB_URL" "$k3s_service" "$k3s_config_b64" <<'REMOTE'
set -euo pipefail
DEB_URL=$1
K3S_SERVICE=$2
K3S_CONFIG=$(echo "$3" | base64 -d)

echo "--- Installing deb ---"
curl -sL "$DEB_URL" -o /tmp/pelagos.deb
sudo dpkg -i /tmp/pelagos.deb 2>&1 | tail -5 || sudo apt-get install -f -y 2>&1 | tail -5

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

echo "--- Enabling and starting pelagos-cri ---"
sudo systemctl daemon-reload
sudo systemctl enable pelagos-cri
sudo systemctl restart pelagos-cri
sleep 5
sudo systemctl is-active pelagos-cri

echo "--- Restarting $K3S_SERVICE ---"
sudo systemctl restart "$K3S_SERVICE"

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
