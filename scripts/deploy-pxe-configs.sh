#!/usr/bin/env bash
# Deploys PXE autoinstall user-data files from repo to nazgul.
# Run from omen after committing changes to pxe/autoinstall/.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NAZGUL_PXE="root@nazgul:/mnt/primary_storage/pxe_assets/autoinstall"

for dir in "$REPO"/pxe/autoinstall/*/; do
    mac="$(basename "$dir")"
    echo "Deploying $mac..."
    scp -o IdentitiesOnly=yes "$dir/user-data" "$dir/meta-data" "${NAZGUL_PXE}/${mac}/"
done

echo "Done."
