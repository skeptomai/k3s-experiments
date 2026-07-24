#!/bin/bash
# Run on ipc8 as root inside the compute container during the failure window.
# Dumps virtqemud config, cmdline, libvirt log dir, qemu.conf, and any internal logs.

set -euo pipefail

echo "=== virtqemud cmdline ==="
cat /proc/$(pgrep -x virtqemud)/cmdline 2>/dev/null | tr '\0' '\n' || echo "(no virtqemud)"

echo ""
echo "=== virtqemud env (LIBVIRT_*) ==="
cat /proc/$(pgrep -x virtqemud)/environ 2>/dev/null | tr '\0' '\n' | grep -i 'libvirt\|debug\|log' || echo "(none)"

echo ""
echo "=== /var/run/libvirt/ files ==="
find /var/run/libvirt/ -type f 2>/dev/null | head -30 || echo "(empty)"

echo ""
echo "=== /etc/libvirt/ files ==="
find /etc/libvirt/ -type f 2>/dev/null | head -20 || echo "(empty)"

echo ""
echo "=== qemu.conf ==="
cat /etc/libvirt/qemu.conf 2>/dev/null | grep -v '^#' | grep -v '^$' || echo "(empty or missing)"

echo ""
echo "=== virtqemud.conf ==="
cat /var/run/libvirt/virtqemud.conf 2>/dev/null || echo "(missing)"

echo ""
echo "=== QEMU log dir ==="
ls -la /var/run/kubevirt-private/libvirt/qemu/log/ 2>/dev/null || echo "(missing)"

echo ""
echo "=== QEMU log content ==="
cat /var/run/kubevirt-private/libvirt/qemu/log/default_cirros-test.log 2>/dev/null || echo "(no log yet)"

echo ""
echo "=== libvirt socket dir ==="
ls -la /var/run/libvirt/qemu/sockets/ 2>/dev/null || echo "(missing)"
