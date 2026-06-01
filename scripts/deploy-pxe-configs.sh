#!/usr/bin/env bash
# Deploys PXE config files from repo to nazgul:
#   - MAC-*.ipxe boot scripts → netbootxyz menus directory
#   - autoinstall user-data/meta-data → pxe_assets/autoinstall/
# Run from omen after committing changes to pxe/.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NAZGUL_MENUS="root@nazgul:/mnt/.ix-apps/app_mounts/netbootxyz/config/menus"
NAZGUL_AUTOINSTALL="root@nazgul:/mnt/primary_storage/pxe_assets/autoinstall"

echo "Deploying MAC iPXE boot scripts..."
for f in "$REPO"/pxe/MAC-*.ipxe; do
    name="$(basename "$f")"
    echo "  $name"
    scp "$f" "${NAZGUL_MENUS}/${name}"
done

echo "Deploying autoinstall configs..."
for dir in "$REPO"/pxe/autoinstall/*/; do
    mac="$(basename "$dir")"
    echo "  $mac"
    scp "$dir/user-data" "$dir/meta-data" "${NAZGUL_AUTOINSTALL}/${mac}/"
done

echo "Done."
