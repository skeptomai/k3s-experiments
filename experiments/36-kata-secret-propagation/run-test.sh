#!/usr/bin/env bash
# Experiment 36: does a rotated Secret reach a running Kata pod? Runs a throwaway
# KubeVirt VM on ipc8 (nested virt) containing single-node k3s + Kata, and times a
# Secret rotation into a Kata pod versus a runc control pod. Run from omen.
set -euo pipefail
NS=kata-secret-test
HERE="$(cd "$(dirname "$0")" && pwd)"
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Debug access: the guest accepts the invoking user's public key (placeholder in the committed file).
PUB="$(cat "${SSH_PUBKEY_FILE:-$HOME/.ssh/id_rsa.pub}")"
UD="$(mktemp)"; trap 'rm -f "$UD"' EXIT
sed "s|__SSH_PUBKEY__|$PUB|" "$HERE/cloud-init.yaml" > "$UD"
kubectl -n "$NS" create secret generic kata-userdata --from-file=userdata="$UD" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "$HERE/vmi.yaml" >/dev/null
log "waiting for VMI"
kubectl -n "$NS" wait --for=condition=Ready vmi/kata-host --timeout=480s
POD="$(kubectl -n "$NS" get pod -l kubevirt.io=virt-launcher -o name | head -1)"
log "launcher pod: $POD; following guest console (up to 45 min)"
END=$(( $(date +%s) + 2700 )); seen=0
while [ "$(date +%s)" -lt "$END" ]; do
  out="$(kubectl -n "$NS" logs "$POD" -c guest-console-log 2>/dev/null | grep -a 'KT:' || true)"
  n=$(wc -l <<<"$out")
  if [ "$n" -gt "$seen" ]; then tail -n +"$((seen+1))" <<<"$out"; seen=$n; fi
  grep -q 'KT: RESULT_DONE\|KT: FATAL' <<<"$out" && break
  sleep 10
done
