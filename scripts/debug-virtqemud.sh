#!/bin/bash
# Debug virtqemud crash: captures FDs, mounts, and any log content from virtqemud
# while it's briefly alive, then follows the QEMU child's stderr.
# Run on the target node BEFORE applying the VMI.
# Usage: sudo bash scripts/debug-virtqemud.sh

set -euo pipefail

OUTDIR="/tmp/virtqemud-debug-$(date +%s)"
mkdir -p "$OUTDIR"
echo "Output dir: $OUTDIR"

echo "Waiting for virtqemud..."
for i in $(seq 1 120); do
    PID=$(pgrep -x virtqemud 2>/dev/null || true)
    [ -n "$PID" ] && break
    sleep 0.1
done

if [ -z "$PID" ]; then
    echo "ERROR: virtqemud never appeared"
    exit 1
fi
echo "Found virtqemud PID=$PID"

# Capture everything we can immediately
cat /proc/$PID/mounts > "$OUTDIR/mounts.txt" 2>/dev/null || true
ls -la /proc/$PID/fd/ > "$OUTDIR/fd-list.txt" 2>/dev/null || true
ls -la /proc/$PID/root/dev/ > "$OUTDIR/root-dev.txt" 2>/dev/null || true
ls -la /proc/$PID/root/sys/fs/cgroup/ > "$OUTDIR/root-cgroup.txt" 2>/dev/null || true
cat /proc/$PID/status > "$OUTDIR/status.txt" 2>/dev/null || true
cat /proc/$PID/environ | tr '\0' '\n' > "$OUTDIR/environ.txt" 2>/dev/null || true

# Find which fds are writable files (logs)
echo "--- FD symlink targets ---" >> "$OUTDIR/fd-list.txt"
for fd in /proc/$PID/fd/*; do
    target=$(readlink "$fd" 2>/dev/null || echo "?")
    echo "$fd -> $target" >> "$OUTDIR/fd-list.txt"
done

# Look for a log file via fd
for fd in /proc/$PID/fd/*; do
    target=$(readlink "$fd" 2>/dev/null || true)
    # If target looks like a log file and exists as a regular file, tail it
    if echo "$target" | grep -qiE '(log|\.txt|libvirt|qemu)' 2>/dev/null; then
        fdnum=$(basename "$fd")
        echo "Capturing fd=$fdnum -> $target"
        cat /proc/$PID/fd/$fdnum > "$OUTDIR/fd-$fdnum-log.txt" 2>/dev/null || true
    fi
done

# Wait for virtqemud to die and capture any children that appear
echo "virtqemud alive; watching for QEMU child..."
for i in $(seq 1 50); do
    QPID=$(pgrep -x qemu-kvm 2>/dev/null || true)
    if [ -n "$QPID" ]; then
        echo "Found qemu-kvm PID=$QPID"
        cat /proc/$QPID/cmdline | tr '\0' '\n' > "$OUTDIR/qemu-cmdline.txt" 2>/dev/null || true
        ls -la /proc/$QPID/root/dev/ > "$OUTDIR/qemu-root-dev.txt" 2>/dev/null || true
        # Check if /dev/kvm exists in the qemu process view
        ls -la /proc/$QPID/root/dev/kvm > "$OUTDIR/qemu-dev-kvm.txt" 2>/dev/null || echo "MISSING" > "$OUTDIR/qemu-dev-kvm.txt"
        break
    fi
    sleep 0.05
done

# Wait for virtqemud to exit
echo "Waiting for virtqemud to exit..."
timeout 30 tail --pid=$PID -f /dev/null 2>/dev/null || true
echo "virtqemud exited"

# After virtqemud dies, look at its log file if we recorded the path
# Also check the virt-launcher-monitor log files in /tmp or /var/run
find /var/run/libvirt/ -type f 2>/dev/null | head -20 >> "$OUTDIR/libvirt-runtime-files.txt" || true
find /var/lib/kubelet/pods -name "*.log" -newer /tmp 2>/dev/null | head -10 >> "$OUTDIR/kubelet-logs.txt" || true

# Print summary
echo ""
echo "=== RESULTS IN $OUTDIR ==="
echo ""
echo "--- mounts (cgroup lines) ---"
grep -i cgroup "$OUTDIR/mounts.txt" || echo "(none)"
echo ""
echo "--- root/sys/fs/cgroup ---"
cat "$OUTDIR/root-cgroup.txt"
echo ""
echo "--- root/dev (kvm, tun, vhost) ---"
grep -E "(kvm|tun|vhost)" "$OUTDIR/root-dev.txt" || echo "(none found)"
echo ""
echo "--- environ (LIBVIRT) ---"
grep -i libvirt "$OUTDIR/environ.txt" || echo "(none)"
echo ""
echo "--- FD list ---"
cat "$OUTDIR/fd-list.txt"
echo ""
for f in "$OUTDIR"/fd-*-log.txt; do
    [ -f "$f" ] || continue
    echo "--- $f ---"
    cat "$f"
done
