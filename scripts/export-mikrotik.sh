#!/usr/bin/env bash
# Export MikroTik out-of-band config to docs/mikrotik/ as RouterOS script files.
# Run this after making changes to the router to keep the repo in sync.
# Output is diffable RouterOS script syntax — paste back into a RouterOS terminal to restore.
set -euo pipefail

ROUTER=192.168.88.1
OUTDIR="$(cd "$(dirname "$0")/../docs/mikrotik" && pwd)"

echo "==> Exporting from $ROUTER..."

ssh "admin@$ROUTER" "/ip dns static export"       > "$OUTDIR/dns-static.rsc"
echo "    dns-static.rsc"

ssh "admin@$ROUTER" "/ip dhcp-server lease export" > "$OUTDIR/dhcp-leases.rsc"
echo "    dhcp-leases.rsc"

echo "==> Done. Review changes with: git diff docs/mikrotik/"
