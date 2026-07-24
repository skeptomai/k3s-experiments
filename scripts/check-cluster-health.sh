#!/bin/bash
# Cluster health summary.
# Catches what "kubectl get nodes" alone misses: CrashLoopBackOff pods,
# non-ready DaemonSets, stuck Flux kustomizations.
# Exit 0 = all healthy. Exit 1 = one or more checks failed.

KUBECTL="sudo kubectl"
FAIL=0

section() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  OK   %s\n' "$*"; }
warn() { printf '  WARN %s\n' "$*"; FAIL=1; }
fail() { printf '  FAIL %s\n' "$*"; FAIL=1; }

# --- Nodes ---
section "Nodes"
NOT_READY=$($KUBECTL get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print}')
[ -z "$NOT_READY" ] && ok "All nodes Ready" || { fail "Nodes not Ready:"; echo "$NOT_READY"; }

# --- CrashLoopBackOff ---
# field-selector phase!=Running misses CrashLoopBackOff — the pod is Running,
# the *container* is crash-looping. Must check containerStatuses directly.
section "CrashLoopBackOff pods"
CLBO=$($KUBECTL get pods -A -o json 2>/dev/null | python3 -c "
import sys, json
bad = []
for p in json.load(sys.stdin)['items']:
    ns   = p['metadata']['namespace']
    name = p['metadata']['name']
    for css in ('containerStatuses', 'initContainerStatuses'):
        for cs in p.get('status', {}).get(css, []):
            if cs.get('state', {}).get('waiting', {}).get('reason') == 'CrashLoopBackOff':
                bad.append(f\"{ns}/{name}  container={cs['name']}  restarts={cs['restartCount']}\")
for line in bad:
    print(line)
")
[ -z "$CLBO" ] && ok "None" || { fail "Found CrashLoopBackOff:"; echo "$CLBO"; }

# --- Other stuck pods (Pending / Failed / Unknown) ---
section "Pods not Running/Completed"
STUCK=$($KUBECTL get pods -A --no-headers 2>/dev/null \
    | awk '$4 != "Running" && $4 != "Completed" && $4 != "Succeeded" {print}')
[ -z "$STUCK" ] && ok "None" || { warn "Found:"; echo "$STUCK"; }

# --- Flux kustomizations ---
section "Flux Kustomizations"
# Columns: NAMESPACE  NAME  AGE  READY  STATUS
NOT_READY_KS=$($KUBECTL get kustomization -A --no-headers 2>/dev/null \
    | awk '$4 != "True" {print}')
[ -z "$NOT_READY_KS" ] && ok "All True" || { warn "Not ready:"; echo "$NOT_READY_KS"; }

# --- MetalLB speakers ---
section "MetalLB speakers"
IFS=',' read -r DESIRED READY <<< "$($KUBECTL get ds speaker -n metallb-system \
    -o jsonpath='{.status.desiredNumberScheduled},{.status.numberReady}' 2>/dev/null || echo '0,0')"
if [ "${READY:-0}" = "${DESIRED:-0}" ] && [ "${DESIRED:-0}" -gt 0 ]; then
    ok "$READY/$DESIRED Ready"
else
    fail "$READY/$DESIRED Ready — likely orphaned speaker process holding port 7946 on a node"
fi

# --- SPIRE agents ---
section "SPIRE agents"
IFS=',' read -r DESIRED READY <<< "$($KUBECTL get ds spire-agent -n spire \
    -o jsonpath='{.status.desiredNumberScheduled},{.status.numberReady}' 2>/dev/null || echo '0,0')"
if [ "${READY:-0}" = "${DESIRED:-0}" ] && [ "${DESIRED:-0}" -gt 0 ]; then
    ok "$READY/$DESIRED Ready"
else
    fail "$READY/$DESIRED Ready — agents may have stale trust bundle; recycle with: kubectl delete pods -n spire -l app=spire-agent"
fi

# --- Summary ---
echo
if [ $FAIL -eq 0 ]; then
    echo "All checks passed."
else
    echo "One or more checks FAILED — see above."
fi
exit $FAIL
