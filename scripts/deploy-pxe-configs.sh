#!/usr/bin/env bash
# Deploys PXE config files from repo to nazgul:
#   - MAC-*.ipxe boot scripts → netbootxyz menus directory
#   - autoinstall user-data/meta-data → pxe_assets/autoinstall/
# Run from omen after committing changes to pxe/.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NAZGUL_MENUS_PATH="/mnt/.ix-apps/app_mounts/netbootxyz/config/menus"
NAZGUL_MENUS="root@nazgul:${NAZGUL_MENUS_PATH}"
NAZGUL_AI_PATH="/mnt/primary_storage/pxe_assets/autoinstall"
NAZGUL_AUTOINSTALL="root@nazgul:${NAZGUL_AI_PATH}"

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
    # Create the dir with mode 0755 FIRST — nginx (the netboot asset server)
    # needs the traverse (x) bit to serve user-data/meta-data, or cloud-init
    # gets 403 and the autoinstall stalls. A bare scp into a missing dir left
    # it 0744 (no group/other x), which silently broke new nodes' installs.
    ssh root@nazgul "mkdir -p '${NAZGUL_AI_PATH}/${mac}' && chmod 755 '${NAZGUL_AI_PATH}/${mac}'"
    scp "$dir/user-data" "$dir/meta-data" "${NAZGUL_AUTOINSTALL}/${mac}/"
    ssh root@nazgul "chmod 644 '${NAZGUL_AI_PATH}/${mac}/user-data' '${NAZGUL_AI_PATH}/${mac}/meta-data'"
done

echo "Done."
