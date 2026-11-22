#!/usr/bin/env bash
# Experiment 34: does a rotated Secret reach a running KubeVirt guest, and does a
# service pick it up? Uses a real CA + two leaf certificates (A, then B).
# Run from omen. Throwaway namespace kv-secret-test; remove with teardown.sh.
set -euo pipefail

NS=kv-secret-test
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f' | cut -c1-8; }

log "generating CA and two leaf certificates"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" -out "$WORK/ca.crt" \
  -days 2 -subj "/CN=kv-secret-test-ca" 2>/dev/null
mkleaf() {
  local n="$1"
  openssl req -newkey rsa:2048 -nodes -keyout "$WORK/$n.key" -out "$WORK/$n.csr" \
    -subj "/CN=hcp-test-$n" 2>/dev/null
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > "$WORK/$n.ext"
  openssl x509 -req -in "$WORK/$n.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
    -CAcreateserial -out "$WORK/$n.crt" -days 1 -extfile "$WORK/$n.ext" 2>/dev/null
}
mkleaf A; mkleaf B
FP_A="$(fp "$WORK/A.crt")"; FP_B="$(fp "$WORK/B.crt")"
log "leaf A fingerprint $FP_A, leaf B fingerprint $FP_B"

put_secret() {
  kubectl -n "$NS" create secret generic tls-test \
    --from-file=tls.crt="$WORK/$1.crt" --from-file=tls.key="$WORK/$1.key" \
    --from-file=ca.crt="$WORK/ca.crt" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
put_secret A
kubectl -n "$NS" create secret generic probe-userdata --from-file=userdata="$HERE/cloud-init.yaml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log "applying VMI (Secret holds leaf A)"
kubectl apply -f "$HERE/vmi.yaml" >/dev/null
kubectl -n "$NS" wait --for=condition=Ready vmi/secret-probe --timeout=480s
POD="$(kubectl -n "$NS" get pod -l kubevirt.io=virt-launcher -o name | head -1)"
log "launcher pod: $POD"
lastprobe() { kubectl -n "$NS" logs "$POD" -c guest-console-log 2>/dev/null | grep -a PROBE | tail -1 || true; }
field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<"$2"; }

log "waiting for guest baseline (all four sources show A)"
ok=0
for _ in $(seq 1 90); do
  L="$(lastprobe)"
  if [ -n "$L" ] && [ "$(field disk "$L")" = "$FP_A" ] && [ "$(field fs "$L")" = "$FP_A" ] \
     && [ "$(field svc_static "$L")" = "$FP_A" ] && [ "$(field svc_dyn "$L")" = "$FP_A" ]; then ok=1; break; fi
  sleep 5
done
if [ "$ok" != 1 ]; then
  log "BASELINE NOT REACHED. Last probe: ${L:-<none>}"
  log "console markers:"; kubectl -n "$NS" logs "$POD" -c guest-console-log 2>/dev/null \
    | grep -a -E 'FAILED|NOT_FOUND|BOOT_DONE|SERVICE_START' | tail -5 || true
  exit 2
fi
log "baseline OK: $L"

T0="$(date +%s)"
log "ROTATING: Secret now holds leaf B (T0)"
put_secret B

declare -A seen=([disk]="" [fs]="" [svc_static]="" [svc_dyn]="")
LIMIT=420
while [ $(( $(date +%s) - T0 )) -lt "$LIMIT" ]; do
  L="$(lastprobe)"
  for k in disk fs svc_static svc_dyn; do
    if [ -z "${seen[$k]}" ] && [ "$(field "$k" "$L")" = "$FP_B" ]; then
      seen[$k]=$(( $(date +%s) - T0 ))
      log "$k switched to B after ${seen[$k]}s"
    fi
  done
  [ -n "${seen[disk]}" ] && [ -n "${seen[fs]}" ] && [ -n "${seen[svc_static]}" ] && [ -n "${seen[svc_dyn]}" ] && break
  sleep 5
done

echo
echo "RESULT (seconds from Secret update until the guest saw leaf B; resolution ~5-10s)"
for k in disk fs svc_static svc_dyn; do
  if [ -n "${seen[$k]}" ]; then r="${seen[$k]}s"; else r="not seen within ${LIMIT}s"; fi
  printf '  %-11s %s\n' "$k" "$r"
done
echo "  final probe: $(lastprobe)"
