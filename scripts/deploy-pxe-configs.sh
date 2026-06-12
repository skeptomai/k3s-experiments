#!/usr/bin/env bash
# Deploys PXE config files from repo to nazgul:
#   - MAC-*.ipxe boot scripts → netbootxyz menus directory
#   - autoinstall user-data/meta-data → pxe_assets/autoinstall/
# Run from omen after committing changes to pxe/.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NAZGUL_MENUS_PATH="/mnt/.ix-apps/app_mounts/netbootxyz/config/menus"
NAZGUL_MENUS="root@nazgul:${NAZGUL_MENUS_PATH}"
NAZGUL_AUTOINSTALL="root@nazgul:/mnt/primary_storage/pxe_assets/autoinstall"

echo "Deploying pxe-control.sh to nazgul..."
scp "$REPO/scripts/pxe-control.sh" "root@nazgul:~/pxe-control.sh"

echo "Deploying MAC iPXE boot scripts (as disabled)..."
for f in "$REPO"/pxe/MAC-*.ipxe; do
    name="$(basename "$f")"
    echo "  $name"
    scp "$f" "${NAZGUL_MENUS}/${name}.disabled"
    ssh root@nazgul "chown apps:apps ${NAZGUL_MENUS_PATH}/${name}.disabled"
done

echo "Deploying autoinstall configs..."
for dir in "$REPO"/pxe/autoinstall/*/; do
    mac="$(basename "$dir")"
    echo "  $mac"
    scp "$dir/user-data" "$dir/meta-data" "${NAZGUL_AUTOINSTALL}/${mac}/"
done

echo "Deploying set-pxe-first.sh to pxe_assets (served at :31011)..."
scp "$REPO/pxe/set-pxe-first.sh" "root@nazgul:/mnt/primary_storage/pxe_assets/set-pxe-first.sh"

echo "Done."
