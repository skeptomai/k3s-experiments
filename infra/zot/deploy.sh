#!/usr/bin/env bash
# Deploys the Zot registry stack to nazgul from this repo (the source of truth).
# Rsyncs docker-compose.yml + config/ and runs `docker compose up -d`.
#
# Run from omen. Reaches nazgul over the tailnet by default (works on- and
# off-LAN); override with NAZGUL=root@192.168.89.2 on the home network.
#
# Usage: bash infra/zot/deploy.sh
set -euo pipefail

NAZGUL="${NAZGUL:-root@nazgul.taildd208.ts.net}"
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="/mnt/primary_storage/zot"

echo "=== Syncing compose + configs to $NAZGUL:$DEST ==="
rsync -av --no-perms --no-owner --no-group \
    "$SRC/docker-compose.yml" \
    "$NAZGUL:$DEST/docker-compose.yml"
rsync -av --no-perms --no-owner --no-group \
    "$SRC/config/" \
    "$NAZGUL:$DEST/config/"

echo "=== docker compose up -d ==="
ssh "$NAZGUL" "cd $DEST && docker compose up -d"

echo "=== Health check (5000-5004) ==="
ssh "$NAZGUL" 'for p in 5000 5001 5002 5003 5004; do printf "port %s: " "$p"; curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://localhost:$p/v2/"; done'
