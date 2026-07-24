#!/bin/bash
# Test AppArmor security_driver hypothesis for KubeVirt QEMU failure.
# Requires an active virt-launcher pod with a running compute container.
#
# Usage:
#   bash scripts/test-apparmor-fix.sh <pod-name> [phase]
#
# phase=1 (default): confirm AppArmor error via virsh (no fix applied)
# phase=2: apply security_driver=none fix, restart virtqemud, test again

set -euo pipefail

POD="${1:-}"
PHASE="${2:-1}"

if [ -z "$POD" ]; then
    # Auto-detect the first 3/3 Running launcher pod
    POD=$(kubectl get pods -n default -l kubevirt.io=virt-launcher --no-headers 2>/dev/null | grep " 3/3 " | head -1 | awk '{print $1}')
    if [ -z "$POD" ]; then
        echo "ERROR: no running virt-launcher pod found. Apply the VMI first."
        exit 1
    fi
fi

echo "[$(date +%T)] Using pod: $POD"

# Create minimal test disk
echo "[$(date +%T)] Creating test disk..."
kubectl exec "$POD" -c compute -- qemu-img create -f qcow2 /tmp/test.qcow2 64M 2>/dev/null || true

# Create minimal domain XML
echo "[$(date +%T)] Writing test domain XML..."
kubectl exec "$POD" -c compute -- bash -c 'cat > /tmp/test.xml << '"'"'XMLEOF'"'"'
<domain type="kvm">
  <name>apparmor-test</name>
  <memory unit="KiB">65536</memory>
  <vcpu>1</vcpu>
  <os>
    <type arch="x86_64" machine="q35">hvm</type>
  </os>
  <devices>
    <emulator>/usr/libexec/qemu-kvm</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2"/>
      <source file="/tmp/test.qcow2"/>
      <target dev="vda" bus="virtio"/>
    </disk>
  </devices>
</domain>
XMLEOF'

if [ "$PHASE" = "2" ]; then
    # Apply the fix: add security_driver = "none" to qemu.conf
    echo "[$(date +%T)] Applying fix: security_driver = none..."
    kubectl exec "$POD" -c compute -- bash -c 'echo "security_driver = \"none\"" >> /var/run/kubevirt-private/libvirt/qemu.conf'
    echo "[$(date +%T)] qemu.conf after patch:"
    kubectl exec "$POD" -c compute -- cat /var/run/kubevirt-private/libvirt/qemu.conf

    # Kill virtqemud so it restarts reading the new config
    echo "[$(date +%T)] Killing virtqemud to force config reload..."
    VPID=$(kubectl exec "$POD" -c compute -- bash -c 'pgrep virtqemud | head -1' 2>/dev/null || true)
    if [ -n "$VPID" ]; then
        kubectl exec "$POD" -c compute -- kill "$VPID" || true
    fi

    # Wait for virtqemud to restart (or detect if pod died)
    echo "[$(date +%T)] Waiting for virtqemud restart..."
    for i in $(seq 1 30); do
        READY=$(kubectl get pod "$POD" -n default --no-headers 2>/dev/null | grep " 3/3 " | wc -l)
        if [ "$READY" = "0" ]; then
            echo "[$(date +%T)] Pod is no longer 3/3 - virt-launcher may have exited"
            kubectl get pod "$POD" -n default --no-headers 2>/dev/null
            exit 1
        fi
        NVPID=$(kubectl exec "$POD" -c compute -- bash -c 'pgrep virtqemud | head -1' 2>/dev/null || true)
        if [ -n "$NVPID" ] && [ "$NVPID" != "$VPID" ]; then
            echo "[$(date +%T)] virtqemud restarted (PID=$NVPID)"
            break
        fi
        sleep 1
    done
    sleep 2  # let virtqemud fully initialize
fi

# Try to create domain via virsh
echo "[$(date +%T)] Attempting virsh domain create (phase=$PHASE)..."
if kubectl exec "$POD" -c compute -- virsh -c qemu:///session create /tmp/test.xml 2>&1; then
    echo "[$(date +%T)] SUCCESS: domain created without AppArmor error!"
    echo "[$(date +%T)] Checking if QEMU is running..."
    kubectl exec "$POD" -c compute -- virsh -c qemu:///session list 2>&1 || true
else
    echo "[$(date +%T)] FAILED: domain create failed (see error above)"
fi
