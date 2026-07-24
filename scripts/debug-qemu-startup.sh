#!/bin/bash
# Race to enable virtqemud debug logging in a new compute container before domain creation.
# Run from omen. Polls until the pod appears, then immediately execs in.
# Usage: ./debug-qemu-startup.sh

set -euo pipefail

echo "Applying VMI..."
kubectl apply -f /home/cb/Projects/k3s-experiments/experiments/25-kubevirt-vm/vmi-cirros.yaml

echo "Waiting for virt-launcher pod..."
POD=""
for i in $(seq 1 60); do
    POD=$(kubectl get pods -l kubevirt.io=virt-launcher --field-selector=spec.nodeName=ipc8 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$POD" ] && [ "$POD" != "" ]; then
        echo "Found pod: $POD"
        break
    fi
    sleep 0.5
done

if [ -z "$POD" ]; then
    echo "ERROR: No pod found"
    exit 1
fi

# Poll until compute container is ready, then immediately set debug logging
echo "Waiting for compute container to be ready..."
for i in $(seq 1 60); do
    READY=$(kubectl get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="compute")].ready}' 2>/dev/null || true)
    if [ "$READY" = "true" ]; then
        echo "Compute ready! Setting debug logging immediately..."
        kubectl exec "$POD" -c compute -- sh -c '
            virt-admin -c virtqemud:///session daemon-log-outputs "5:file:/tmp/vqd.log" 2>/dev/null
            echo "=== debug logging set ==="
            echo "=== /dev/kvm ==="
            ls -la /dev/kvm /dev/vhost-net /dev/tun 2>&1
            echo "=== caps ==="
            cat /proc/self/status | grep -E "Cap|Uid|Groups"
            echo "=== virtqemud pid ==="
            cat /var/run/libvirt/virtqemud.pid
        ' 2>&1
        break
    fi
    sleep 0.2
done

echo "Waiting for domain creation attempt..."
sleep 5

# Now read the debug log and QEMU log
echo "=== QEMU LOG ==="
kubectl exec "$POD" -c compute -- cat /var/run/kubevirt-private/libvirt/qemu/log/default_cirros-test.log 2>/dev/null || echo "(no qemu log)"

echo ""
echo "=== VIRTQEMUD DEBUG LOG ==="
kubectl exec "$POD" -c compute -- cat /tmp/vqd.log 2>/dev/null | grep -v "^$" | head -100 || echo "(no debug log)"

echo ""
echo "=== VMI STATUS ==="
kubectl get vmi cirros-test -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null
