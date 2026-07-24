#!/bin/bash
# Enable libvirt debug logging on a fresh virtqemud.
# Run BEFORE applying the VMI. Waits for virtqemud to appear, sets debug
# filters via nsenter+virt-admin, then reads the domain log after failure.
#
# Usage on ipc8:
#   sudo bash /tmp/libvirt-debug-log.sh > /tmp/libvirt-debug.log 2>&1 &

set -euo pipefail
OUTLOG=/tmp/libvirt-domainlog-$(date +%s).log

# Wait for any existing virtqemud to die
for i in $(seq 1 300); do
    [ -z "$(pgrep -x virtqemud 2>/dev/null || true)" ] && break
    sleep 0.1
done
echo "[$(date +%T)] Waiting for fresh virtqemud..."

# Wait for a fresh virtqemud
VIRT_PID=""
for i in $(seq 1 300); do
    VIRT_PID=$(pgrep -x virtqemud 2>/dev/null | head -1 || true)
    [ -n "$VIRT_PID" ] && break
    sleep 0.1
done

if [ -z "$VIRT_PID" ]; then
    echo "ERROR: no virtqemud appeared within 30s"
    exit 1
fi
echo "[$(date +%T)] Found virtqemud PID=$VIRT_PID"

# Wait for the socket to appear
for i in $(seq 1 100); do
    [ -S "/proc/$VIRT_PID/root/run/libvirt/virtqemud-admin-sock" ] && break
    sleep 0.1
done
echo "[$(date +%T)] virtqemud admin socket ready"

# Enter the container's mount+UTS+IPC namespaces and run virt-admin as UID=107 (qemu)
# The admin socket is at /run/libvirt/virtqemud-admin-sock inside the container
nsenter -m -u -i -t "$VIRT_PID" -- \
    runuser -u nut -- \
    /usr/bin/virt-admin \
    -c "virtqemud:///session" \
    daemon-log-filters "4:virCommand 4:qemu 4:security 4:util 4:process" 2>&1 && \
    echo "[$(date +%T)] Log filters set" || \
    echo "[$(date +%T)] WARNING: virt-admin filter set failed"

nsenter -m -u -i -t "$VIRT_PID" -- \
    runuser -u nut -- \
    /usr/bin/virt-admin \
    -c "virtqemud:///session" \
    daemon-log-outputs "4:stderr" 2>&1 && \
    echo "[$(date +%T)] Log outputs set" || \
    echo "[$(date +%T)] WARNING: virt-admin output set failed"

echo "[$(date +%T)] Watching for domain create attempt (up to 60s)..."
sleep 60

echo "[$(date +%T)] Reading domain log from container filesystem..."
find /proc/"$VIRT_PID"/root/var/run/kubevirt-private/libvirt/qemu/log/ \
    -name "*.log" 2>/dev/null | while read -r logfile; do
    echo "=== $logfile ==="
    cat "$logfile"
done
echo "[$(date +%T)] Done."
