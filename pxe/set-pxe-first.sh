#!/usr/bin/env bash
# Re-assert network-first EFI boot order after an Ubuntu install.
#
# The Ubuntu installer (grub-install → efibootmgr) prepends its "ubuntu" entry
# to BootOrder on EVERY install, flipping a node to disk-first and breaking PXE
# reinstall + smart-outlet power-cycle recovery. Running this as the LAST
# autoinstall late-command makes our write win (last-writer-wins on the shared
# EFI BootOrder NVRAM variable). Network-first is safe for normal boots: PXE
# falls through to local disk when nazgul returns no autoinstall for the MAC.
#
# Covers both node types: HP/Intel label the PXE entry "IPV4 Network", the
# Realtek-NIC Pentium nodes label it "PXE IP4".
set -uo pipefail

command -v efibootmgr >/dev/null 2>&1 || { echo "set-pxe-first: efibootmgr not found"; exit 0; }

# Boot order changes need efivars mounted writable.
if ! mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
  mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
fi

current=$(efibootmgr | sed -n 's/^BootOrder: //p' | tr -d ' ')
[ -n "$current" ] || { echo "set-pxe-first: no BootOrder, skipping"; exit 0; }

# IPv4 PXE/network boot entry numbers (one or more).
pxe=$(efibootmgr | grep -iE 'IPV4 Network|PXE IP4' \
        | grep -oiE '^Boot[0-9A-F]{4}' | grep -oiE '[0-9A-F]{4}' | tr '\n' ' ')
[ -n "$pxe" ] || { echo "set-pxe-first: no IPv4 PXE entry found, skipping"; exit 0; }

# New order: PXE IPv4 first, then the rest of the existing order (deduped).
new=""
for b in $pxe; do new="${new:+$new,}$b"; done
IFS=','
for b in $current; do
  case " $pxe " in *" $b "*) ;; *) new="$new,$b";; esac
done
unset IFS

if efibootmgr --bootorder "$new" >/dev/null 2>&1; then
  echo "set-pxe-first: BootOrder -> $new"
else
  echo "set-pxe-first: efibootmgr --bootorder failed (efivars not writable?)" >&2
fi
