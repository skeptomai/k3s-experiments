#!/bin/bash
# Cluster health summary — ASCII table output.
# Catches what "kubectl get nodes" alone misses: CrashLoopBackOff pods,
# non-ready DaemonSets, stuck Flux kustomizations.
# Exit 0 = all healthy. Exit 1 = one or more checks failed.

KUBECTL="sudo kubectl"
FAIL=0

# Collected results: parallel arrays
NAMES=()
STATUSES=()
DETAILS=()
EXTRAS=()   # multi-line detail printed below the table on failure

add() {
    local name="$1" status="$2" detail="$3" extra="${4:-}"
    NAMES+=("$name")
    STATUSES+=("$status")
    DETAILS+=("$detail")
    EXTRAS+=("$extra")
    [ "$status" != "OK" ] && FAIL=1
}

# --- Nodes ---
NOT_READY=$($KUBECTL get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print}')
if [ -z "$NOT_READY" ]; then
    add "Nodes" "OK" "All 6 Ready"
else
    COUNT=$(echo "$NOT_READY" | wc -l | tr -d ' ')
    add "Nodes" "FAIL" "$COUNT not Ready — see below" "$NOT_READY"
fi

# --- CrashLoopBackOff ---
# field-selector phase!=Running misses these — pod is Running, container is
# crash-looping. Must check containerStatuses directly.
CLBO=$($KUBECTL get pods -A -o json 2>/dev/null | python3 -c "
import sys, json
bad = []
for p in json.load(sys.stdin)['items']:
    ns, name = p['metadata']['namespace'], p['metadata']['name']
    for css in ('containerStatuses', 'initContainerStatuses'):
        for cs in p.get('status', {}).get(css, []):
            if cs.get('state', {}).get('waiting', {}).get('reason') == 'CrashLoopBackOff':
                bad.append(f\"{ns}/{name}  container={cs['name']}  restarts={cs['restartCount']}\")
print('\n'.join(bad))
")
if [ -z "$CLBO" ]; then
    add "CrashLoopBackOff pods" "OK" "None"
else
    COUNT=$(echo "$CLBO" | wc -l | tr -d ' ')
    add "CrashLoopBackOff pods" "FAIL" "$COUNT pod(s) — see below" "$CLBO"
fi

# --- Other stuck pods ---
STUCK=$($KUBECTL get pods -A --no-headers 2>/dev/null \
    | awk '$4 != "Running" && $4 != "Completed" && $4 != "Succeeded" {print}')
if [ -z "$STUCK" ]; then
    add "Pods not Running/Completed" "OK" "None"
else
    COUNT=$(echo "$STUCK" | wc -l | tr -d ' ')
    add "Pods not Running/Completed" "WARN" "$COUNT pod(s) — see below" "$STUCK"
fi

# --- Flux kustomizations ---
# Columns: NAMESPACE  NAME  AGE  READY  STATUS
NOT_READY_KS=$($KUBECTL get kustomization -A --no-headers 2>/dev/null \
    | awk '$4 != "True" {print}')
if [ -z "$NOT_READY_KS" ]; then
    add "Flux Kustomizations" "OK" "All True"
else
    COUNT=$(echo "$NOT_READY_KS" | wc -l | tr -d ' ')
    add "Flux Kustomizations" "WARN" "$COUNT not ready — see below" "$NOT_READY_KS"
fi

# --- MetalLB speakers ---
IFS=',' read -r DESIRED READY <<< "$($KUBECTL get ds speaker -n metallb-system \
    -o jsonpath='{.status.desiredNumberScheduled},{.status.numberReady}' 2>/dev/null || echo '0,0')"
if [ "${READY:-0}" = "${DESIRED:-0}" ] && [ "${DESIRED:-0}" -gt 0 ]; then
    add "MetalLB speakers" "OK" "$READY/$DESIRED Ready"
else
    add "MetalLB speakers" "FAIL" "$READY/$DESIRED Ready — check port 7946 orphans"
fi

# --- SPIRE agents ---
IFS=',' read -r DESIRED READY <<< "$($KUBECTL get ds spire-agent -n spire \
    -o jsonpath='{.status.desiredNumberScheduled},{.status.numberReady}' 2>/dev/null || echo '0,0')"
if [ "${READY:-0}" = "${DESIRED:-0}" ] && [ "${DESIRED:-0}" -gt 0 ]; then
    add "SPIRE agents" "OK" "$READY/$DESIRED Ready"
else
    add "SPIRE agents" "FAIL" "$READY/$DESIRED Ready — recycle: kubectl delete pods -n spire -l app=spire-agent"
fi

# --- Render table ---
C1=28; C2=6; C3=44
SEP="+$(printf '%*s' $((C1+2)) | tr ' ' '-')+$(printf '%*s' $((C2+2)) | tr ' ' '-')+$(printf '%*s' $((C3+2)) | tr ' ' '-')+"

echo "$SEP"
printf "| %-*s | %-*s | %-*s |\n" $C1 "Check" $C2 "Status" $C3 "Detail"
echo "$SEP"
for i in "${!NAMES[@]}"; do
    printf "| %-*s | %-*s | %-*s |\n" $C1 "${NAMES[$i]}" $C2 "${STATUSES[$i]}" $C3 "${DETAILS[$i]}"
done
echo "$SEP"

# --- Summary + extras ---
echo
if [ $FAIL -eq 0 ]; then
    echo "All checks passed."
else
    echo "One or more checks FAILED."
    for i in "${!NAMES[@]}"; do
        if [ -n "${EXTRAS[$i]}" ]; then
            echo
            echo "${NAMES[$i]}:"
            echo "${EXTRAS[$i]}" | sed 's/^/  /'
        fi
    done
fi

exit $FAIL
