#!/bin/bash
# Downloads Ubuntu 24.04 live server ISO and extracts PXE boot files.
# Run as root on nazgul after cloning/pulling the repo there, or scp this
# script to nazgul and run it directly.
set -euo pipefail

ASSETS=/mnt/primary_storage/pxe_assets
ISO_NAME=ubuntu-24.04-live-server-amd64.iso
ISO_URL=https://releases.ubuntu.com/noble/${ISO_NAME}
ISO_FILE=${ASSETS}/${ISO_NAME}
BOOT_DIR=${ASSETS}/ubuntu-24.04
MOUNT_DIR=/tmp/pxe-iso-mount

mkdir -p "${BOOT_DIR}" "${MOUNT_DIR}"

if [ -f "${ISO_FILE}" ]; then
    echo "ISO already present: ${ISO_FILE}"
else
    echo "Downloading Ubuntu 24.04 live server ISO (~2GB)..."
    wget -q --show-progress -O "${ISO_FILE}" "${ISO_URL}"
fi

echo "Mounting ISO and extracting boot files..."
mount -o loop,ro "${ISO_FILE}" "${MOUNT_DIR}"
cp "${MOUNT_DIR}/casper/vmlinuz" "${BOOT_DIR}/vmlinuz"
cp "${MOUNT_DIR}/casper/initrd" "${BOOT_DIR}/initrd"
umount "${MOUNT_DIR}"
rmdir "${MOUNT_DIR}"

echo ""
echo "Done. Boot files:"
ls -lh "${BOOT_DIR}/"
echo ""
echo "Verify HTTP access from an ipc node:"
echo "  curl -I http://192.168.89.2:31011/ubuntu-24.04/vmlinuz"
