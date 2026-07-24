#!/usr/bin/env bash
# Reproduction script for Pelagos container process leak bug.
#
# Symptom: A container process survives after the container exits/crashes from
# kubelet's perspective, keeping bound ports occupied and blocking all subsequent
# restart attempts (CrashLoopBackOff ×1000+, all failing with EADDRINUSE).
#
# Observed: metallb-system/speaker DaemonSet, all 6 nodes, port 7946.
# The stale speaker process (pid=4300 on ipc4) had been running for 4 days
# while kubelet had recorded 977 restarts of the same pod. `pelagos ps` showed
# the container as "running" and "4 days ago"; `kubectl get pod` showed
# CrashLoopBackOff. Killing the 6 stale pids and deleting the pods restored
# the DaemonSet to 6/6 Ready.
#
# Two reproduction attempts:
#   Test 1 — clean kubectl delete (should NOT leak; baseline)
#   Test 2 — restart pelagos-cri while container is running (suspected trigger)
#
# Usage: bash scripts/repro-pelagos-port-leak.sh [node]
# Default node: ipc8

set -euo pipefail

NODE="${1:-ipc8}"
PORT=17946  # avoid collision with real MetalLB port 7946
NS=default
POD=port-leak-test

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh $SSH_OPTS -J cb@ipc4.taildd208.ts.net cb@$NODE"
CRI="sudo crictl --runtime-endpoint unix:///run/pelagos/cri.sock"

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL (LEAK REPRODUCED): $*"; }

check_leak() {
    local label="$1"
    echo
    echo "--- $label ---"

    local port_held
    port_held=$($SSH "sudo ss -tulnp | grep $PORT || true")
    if [[ -n "$port_held" ]]; then
        fail "port $PORT still held after container exit"
        echo "  $port_held"
    else
        pass "port $PORT is free"
    fi

    local still_running
    still_running=$($SSH "$CRI ps 2>/dev/null | grep $POD || true")
    if [[ -n "$still_running" ]]; then
        fail "container still in crictl ps"
        echo "  $still_running"
    else
        pass "container gone from crictl ps"
    fi

    local nc_procs
    nc_procs=$($SSH "sudo pgrep -a nc 2>/dev/null | grep $PORT || true")
    if [[ -n "$nc_procs" ]]; then
        fail "nc process still alive: $nc_procs"
    else
        pass "no nc process for port $PORT"
    fi
}

apply_pod() {
    kubectl delete pod "$POD" -n "$NS" --ignore-not-found --wait=true 2>/dev/null || true
    local manifest
    manifest=$(mktemp /tmp/port-leak-pod.XXXXXX.yaml)
    # shellcheck disable=SC2064
    trap "rm -f '$manifest'; kubectl delete pod '$POD' -n '$NS' --ignore-not-found 2>/dev/null || true" EXIT
    cat >"$manifest" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
spec:
  nodeSelector:
    kubernetes.io/hostname: $NODE
  restartPolicy: Always
  containers:
    - name: listener
      image: busybox:latest
      command: ["nc", "-lk", "-p", "$PORT", "-s", "0.0.0.0"]
      ports:
        - containerPort: $PORT
EOF
    kubectl apply -f "$manifest"
    kubectl wait pod/"$POD" -n "$NS" --for=condition=Ready --timeout=60s
}

# ─── Header ──────────────────────────────────────────────────────────────────
echo "=== Pelagos port-leak repro on $NODE ==="
echo "Pelagos: $($SSH sudo pelagos --version 2>/dev/null)"
echo

# ─── Test 1: clean kubectl delete ────────────────────────────────────────────
echo "Test 1: clean force-delete via kubectl"
apply_pod

CIDS_BEFORE=$($SSH "$CRI ps 2>/dev/null | grep $POD | awk '{print \$1}'")
echo "  container IDs before kill: ${CIDS_BEFORE:-none}"

kubectl delete pod "$POD" -n "$NS" --grace-period=0 --force 2>/dev/null || true
sleep 5
check_leak "after kubectl delete --force"

# ─── Test 2: pelagos-cri restart while container running ─────────────────────
echo
echo "Test 2: restart pelagos-cri while container holds port"
apply_pod

CIDS_BEFORE=$($SSH "$CRI ps 2>/dev/null | grep $POD | awk '{print \$1}'")
echo "  container IDs before restart: ${CIDS_BEFORE:-none}"
echo "  Port $PORT before restart:"
$SSH "sudo ss -tulnp | grep $PORT || echo '  (nothing)'"

echo "  Restarting pelagos-cri.service ..."
$SSH "sudo systemctl restart pelagos-cri.service"
sleep 10

check_leak "after pelagos-cri restart (10s)"

echo "  Waiting 30s for kubelet to reconcile ..."
sleep 30
check_leak "after pelagos-cri restart (40s)"

echo
echo "=== Done ==="
