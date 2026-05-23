#!/usr/bin/env bash
# Locks down SSH and configures UFW on ipc2 and ipc3.
# Run from any machine with SSH access to ipc1 via the tailnet.
# ipc2 and ipc3 are reached by staging through ipc1.
#
# WARNING: After this script runs, direct SSH to ipc2/ipc3 from any machine
# other than ipc1 will be rejected. Access must go through ipc1.
set -euo pipefail

SERVER="ipc1.taildd208.ts.net"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKERS=(ipc2 ipc3)

echo "=== Locking down worker nodes ==="
echo "After this runs, ipc2 and ipc3 will only accept SSH from ipc1 (192.168.88.53)."
echo ""

for worker in "${WORKERS[@]}"; do
    echo "--- Configuring $worker ---"

    scp -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no \
        "$SCRIPT_DIR/remote/configure-worker.sh" \
        cb@"$SERVER":/tmp/configure-worker.sh

    ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no cb@"$SERVER" \
        "scp -o StrictHostKeyChecking=no /tmp/configure-worker.sh cb@${worker}:/tmp/configure-worker.sh && \
         ssh -o StrictHostKeyChecking=no cb@${worker} 'bash /tmp/configure-worker.sh; rm /tmp/configure-worker.sh'"

    echo "Done: $worker"
    echo ""
done

echo "=== Done ==="
echo "Test access: ssh -i ~/.ssh/id_rsa -J cb@$SERVER cb@ipc2"
