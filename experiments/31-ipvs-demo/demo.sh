#!/usr/bin/env bash
# Demonstrate IPVS least-connection scheduling in action.
#
# What this shows:
#   - The LoadBalancer service (ipvs-demo-lb) gets its own MetalLB IP.
#     Traffic goes: client → IPVS (kube-proxy) → demo pod directly.
#     No Traefik in the path, so /proc/net/ip_vs shows the ACTUAL demo pod
#     IPs as real servers — the lc scheduler is making the routing decision.
#
#   - We open several slow connections (/slow?s=30) in the background.
#     Each held connection increments that pod's active counter.
#     IPVS lc sees the connection counts and steers NEW connections to
#     whichever pod has the fewest active connections.
#
#   - Fast requests (/) reveal which pod handled them and its current
#     active connection count — you can see requests avoiding loaded pods.
#
# Run: bash experiments/31-ipvs-demo/demo.sh
set -euo pipefail

JUMP="cb@ipc4.taildd208.ts.net"
NS="ipvs-demo"
SLOW_PIDS=()

cleanup() {
    echo ""
    echo "==> cleaning up background connections..."
    for pid in "${SLOW_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}
trap cleanup EXIT

# --- helpers ---

get_lb_ip() {
    kubectl get svc ipvs-demo-lb -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null
}

# SSH helper
node_ssh() {
    local node=$1; shift
    if [[ "$node" == "ipc4" ]]; then
        ssh -o BatchMode=yes "$JUMP" "$@"
    else
        ssh -o BatchMode=yes -J "$JUMP" "cb@$node" "$@"
    fi
}

# Parse /proc/net/ip_vs on a node and display the virtual server for a given IP.
# Usage: show_ipvs_on <node> <vip-dotted>
show_ipvs_on() {
    local node=$1 vip=$2
    node_ssh "$node" "awk '
    function h2d(h,    n,i,c) {
        n=0; for(i=1;i<=length(h);i++) {
            c=substr(h,i,1)
            n=n*16 + (c~/[0-9]/ ? c+0 : index(\"abcdef\",tolower(c))+9)
        }; return n
    }
    function hexip(h)   { return h2d(substr(h,1,2))\".\"h2d(substr(h,3,2))\".\"h2d(substr(h,5,2))\".\"h2d(substr(h,7,2)) }
    function hexport(h) { return h2d(h) }
    !/->/ { split(\$2,a,\":\"); cur=hexip(a[1]); in_vip=(cur==\"$vip\"); if(in_vip) printf \"  VIP %s:%d  [scheduler=%s]\\n\",cur,hexport(a[2]),\$3; next }
    in_vip { split(\$2,a,\":\"); printf \"    %-18s  active=%-3d  inactive=%d\\n\",hexip(a[1])\":\"hexport(a[2]),\$5,\$6 }
    ' /proc/net/ip_vs"
}

# Find the MetalLB speaker node for a given VIP by checking which node
# has that IP address on its interface.
find_speaker() {
    local vip=$1
    for node in ipc4 ipc5 ipc6 ipc7 ipc8 ipc9; do
        if node_ssh "$node" "ip -4 addr show | grep -q ' $vip/'" 2>/dev/null; then
            echo "$node"; return
        fi
    done
    echo "ipc4"
}

show_ipvs() {
    local vip=$1
    local speaker
    speaker=$(find_speaker "$vip")
    echo "          (speaker: $speaker)"
    show_ipvs_on "$speaker" "$vip"
}

fast_request() {
    local ip=$1
    curl -s --max-time 5 "http://$ip/" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print('  pod=%-42s  active=%d' % (d['pod'], d['active']))" 2>/dev/null \
        || echo "  (request failed)"
}

divider() { printf '\n%s\n\n' "$(printf '─%.0s' {1..70})"; }

# --- main ---

echo "==> checking pods..."
kubectl wait pods -n "$NS" -l app=ipvs-demo --for=condition=Ready --timeout=120s

LB_IP=$(get_lb_ip)
if [[ -z "$LB_IP" ]]; then
    echo "ERROR: LoadBalancer IP not assigned yet. Is MetalLB running?"
    exit 1
fi
echo "    LoadBalancer IP: $LB_IP"

# Verify connectivity
if ! curl -s --max-time 5 "http://$LB_IP/" > /dev/null 2>&1; then
    echo "ERROR: cannot reach http://$LB_IP/ — is the deployment healthy?"
    exit 1
fi

divider

# ── Phase 1: Baseline ─────────────────────────────────────────────────────────
echo "PHASE 1 — Baseline: 10 fast requests, all pods idle"
echo ""
for i in $(seq 1 10); do fast_request "$LB_IP"; done

divider

# ── Phase 2: Open slow connections ───────────────────────────────────────────
echo "PHASE 2 — Opening 9 slow connections (30s hold each)"
echo "          IPVS lc will distribute them across the 3 pods (~3 each)"
echo ""
for i in $(seq 1 9); do
    curl -s --max-time 40 "http://$LB_IP/slow?s=30" > /dev/null 2>&1 &
    SLOW_PIDS+=($!)
done
sleep 2   # let connections land

echo "          IPVS virtual server for $LB_IP:"
show_ipvs "$LB_IP"
echo ""
echo "          Self-reported active counts from each pod:"
for i in $(seq 1 3); do fast_request "$LB_IP"; done

divider

# ── Phase 3: Fast requests under load ────────────────────────────────────────
echo "PHASE 3 — 10 more fast requests while slow connections are held"
echo "          lc keeps new connections moving to the least-loaded pod"
echo ""
for i in $(seq 1 10); do fast_request "$LB_IP"; done

divider

# ── Phase 4: Wait for connections to drain ───────────────────────────────────
echo "PHASE 4 — releasing slow connections, waiting for drain..."
for pid in "${SLOW_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
SLOW_PIDS=()
wait 2>/dev/null || true
sleep 4   # server detects client disconnect and decrements active counter

echo "          IPVS state after drain (should show active=0):"
show_ipvs "$LB_IP"
echo ""
echo "          fast request after drain (active should be 0):"
fast_request "$LB_IP"

divider

echo "Done. What you saw:"
echo "  Phase 1 → baseline: lc has nothing to do, requests spread round-robin"
echo "  Phase 2 → 9 slow connections: IPVS lc distributed them ~3 per pod"
echo "  Phase 3 → fast requests: new connections routed to least-active pod"
echo "  Phase 4 → drain: active counts return to 0 as slow connections release"
echo ""
echo "Compare to random (iptables default): slow connections would pile up"
echo "unevenly, and new fast requests would land on already-loaded pods."
