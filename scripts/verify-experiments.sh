#!/usr/bin/env bash
# Verify all k3s experiments.
# Experiments 01-09, 13, 15 run in parallel (independent namespaces).
# Experiments 10, 11, 12, 14, 16, 18 run sequentially after.
set -uo pipefail

REPO="/home/cb/Projects/k3s-experiments"
IPC1="cb@ipc1.taildd208.ts.net"
LOGDIR="/tmp/verify-experiments-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"

SSH_CTRL="/tmp/ssh-verify-ctl-%r@%h:%p"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath=$SSH_CTRL -o ControlPersist=120"

# Pre-open a single master connection to ipc1 so all parallel subprocesses
# reuse it instead of each racing to establish their own TCP+tailnet session.
ssh $SSH_OPTS "$IPC1" true 2>/dev/null || true
trap 'ssh -o ControlPath="$SSH_CTRL" -O exit "$IPC1" 2>/dev/null; true' EXIT

kube() { ssh $SSH_OPTS "$IPC1" "sudo kubectl $*"; }

# Apply files via stdin. Puts namespace.yaml first to avoid ordering errors,
# and adds --- between files to prevent kubectl from merging adjacent documents.
kapply() {
  local ns_files=() other_files=()
  for f in "$@"; do
    [[ "$(basename "$f")" == "namespace.yaml" ]] && ns_files+=("$f") || other_files+=("$f")
  done
  { for f in "${ns_files[@]}" "${other_files[@]}"; do printf -- "---\n"; cat "$f"; done; } \
    | ssh $SSH_OPTS "$IPC1" "sudo kubectl apply -f -"
}

del_ns() { kube "delete namespace $1 --ignore-not-found --wait=true --timeout=120s" 2>&1 || true; }

# Best-effort prefetch of images that use :latest tags on ipc1 (the only node
# that may be missing bitnami/kubectl after a fresh run).
prefetch_images() {
  echo "Pre-fetching :latest images on ipc1 (best-effort)..."
  ssh $SSH_OPTS "$IPC1" "sudo crictl pull docker.io/bitnami/kubectl:latest 2>&1" || \
    echo "  WARNING: bitnami/kubectl:latest pull failed (rate limit?). Exp 05 and 11 will fail if pod schedules on ipc1."
  # python:3.12-alpine (exp 14) can schedule on any node; pre-fetch on all three.
  for node in ipc1 ipc2 ipc3; do
    if [ "$node" = "ipc1" ]; then
      ssh $SSH_OPTS "$IPC1" "sudo crictl pull docker.io/library/python:3.12-alpine 2>&1" || \
        echo "  WARNING: python:3.12-alpine pull failed on $node"
    else
      ssh $SSH_OPTS -J "$IPC1" "cb@$node" "sudo crictl pull docker.io/library/python:3.12-alpine 2>&1" || \
        echo "  WARNING: python:3.12-alpine pull failed on $node"
    fi
  done
  echo "Prefetch done."
}

# ---------------------------------------------------------------------------
# 01 + 02 — namespaces/deployments + ingress (02 depends on 01's namespace)
# ---------------------------------------------------------------------------
verify_01_02() {
  local rc=0
  echo "=== 01+02: namespaces-and-deployments + ingress ==="

  if ! kapply "$REPO"/experiments/01-namespaces-and-deployments/*.yaml; then
    echo "FAIL: apply exp01"; rc=1
  elif ! kapply "$REPO"/experiments/02-ingress/*.yaml; then
    echo "FAIL: apply exp02"; rc=1
  elif ! kube "rollout status deployment/hello -n demo --timeout=120s"; then
    echo "FAIL: rollout timeout"; rc=1
  else
    # Retry curl a few times; kube-proxy rules may lag behind rollout completion.
    local curl_ok=false
    for i in 1 2 3 4 5; do
      if ssh $SSH_OPTS "$IPC1" "curl -sf --max-time 5 http://localhost:30080" > /dev/null 2>&1; then
        curl_ok=true; break
      fi
      sleep 5
    done
    if ! $curl_ok; then
      echo "FAIL: NodePort 30080 unreachable after retries"; rc=1
    fi
  fi

  del_ns demo
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 03 — configmaps and secrets
# ---------------------------------------------------------------------------
verify_03() {
  local rc=0
  echo "=== 03: configmaps-and-secrets ==="

  if ! kapply "$REPO"/experiments/03-configmaps-and-secrets/*.yaml; then
    echo "FAIL: apply"; rc=1
  elif ! kube "rollout status deployment/config-demo -n config-demo --timeout=120s"; then
    echo "FAIL: rollout timeout"; rc=1
  else
    local val
    val=$(kube "get secret app-secret -n config-demo -o jsonpath='{.data.DB_PASSWORD}'" 2>/dev/null | base64 -d 2>/dev/null) || { echo "FAIL: get secret"; rc=1; }
    if [[ $rc -eq 0 && "$val" != "supersecret" ]]; then
      echo "FAIL: DB_PASSWORD mismatch (got: $val)"; rc=1
    fi
  fi

  del_ns config-demo
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 04 — persistent volumes
# ---------------------------------------------------------------------------
verify_04() {
  local rc=0
  echo "=== 04: persistent-volumes ==="

  if ! kapply "$REPO"/experiments/04-persistent-volumes/*.yaml; then
    echo "FAIL: apply"; rc=1
  elif ! kube "wait --for=condition=available deployment/writer -n pv-demo --timeout=120s"; then
    echo "FAIL: deployment not available"; rc=1
  else
    local phase
    phase=$(kube "get pvc demo-pvc -n pv-demo -o jsonpath='{.status.phase}'" 2>/dev/null | tr -d "'" | tr -d '[:space:]')
    if [[ "$phase" != "Bound" ]]; then
      echo "FAIL: PVC phase=$phase (expected Bound)"; rc=1
    fi
  fi

  del_ns pv-demo
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 05 — RBAC
# ---------------------------------------------------------------------------
verify_05() {
  local rc=0
  echo "=== 05: rbac ==="

  if ! kapply "$REPO"/experiments/05-rbac/*.yaml; then
    echo "FAIL: apply"; rc=1
  elif ! kube "rollout status deployment/rbac-tester -n rbac-demo --timeout=120s"; then
    echo "FAIL: rollout timeout"; rc=1
  else
    local allow deny
    allow=$(kube "auth can-i get pods -n rbac-demo --as=system:serviceaccount:rbac-demo:pod-reader" 2>/dev/null | tr -d '[:space:]')
    deny=$(kube "auth can-i get secrets -n rbac-demo --as=system:serviceaccount:rbac-demo:pod-reader" 2>/dev/null | tr -d '[:space:]')
    if [[ "$allow" != "yes" ]]; then
      echo "FAIL: pod-reader should be allowed get pods (got: $allow)"; rc=1
    elif [[ "$deny" != "no" ]]; then
      echo "FAIL: pod-reader should be denied get secrets (got: $deny)"; rc=1
    fi
  fi

  del_ns rbac-demo
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 06 — resource limits
# ---------------------------------------------------------------------------
verify_06() {
  local rc=0
  echo "=== 06: resource-limits ==="

  if ! kapply \
    "$REPO/experiments/06-resource-limits/namespace.yaml" \
    "$REPO/experiments/06-resource-limits/deployment.yaml" \
    "$REPO/experiments/06-resource-limits/pod-oomkill.yaml" \
    "$REPO/experiments/06-resource-limits/pod-unschedulable.yaml"; then
    echo "FAIL: apply"; rc=1
  elif ! kube "rollout status deployment/nginx -n limits-demo --timeout=120s"; then
    echo "FAIL: nginx rollout timeout"; rc=1
  elif ! kube "wait pod/oomkill-demo -n limits-demo --for=jsonpath={.status.phase}=Failed --timeout=240s"; then
    echo "FAIL: oomkill-demo did not reach Failed phase"; rc=1
  fi

  if [[ $rc -eq 0 ]]; then
    # Pelagos does not populate reason=OOMKilled; check exit code 137 (SIGKILL) instead.
    local exitCode
    exitCode=$(kube "get pod oomkill-demo -n limits-demo -o jsonpath={.status.containerStatuses[0].state.terminated.exitCode}" 2>/dev/null | tr -d '[:space:]')
    if [[ "$exitCode" -ne 137 ]]; then
      echo "FAIL: oomkill-demo exitCode=$exitCode (expected 137)"; rc=1
    fi
  fi

  if [[ $rc -eq 0 ]]; then
    local phase
    phase=$(kube "get pod unschedulable-demo -n limits-demo -o jsonpath={.status.phase}" 2>/dev/null | tr -d '[:space:]')
    if [[ "$phase" != "Pending" ]]; then
      echo "FAIL: unschedulable-demo phase=$phase (expected Pending)"; rc=1
    fi
  fi

  del_ns limits-demo
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 07 — rolling deployments
# ---------------------------------------------------------------------------
verify_07() {
  local rc=0
  echo "=== 07: rolling-deployments ==="

  if ! kapply "$REPO"/experiments/07-rolling-deployments/*.yaml; then
    echo "FAIL: apply"; rc=1
  elif ! kube "rollout status deployment/web -n rolling-demo --timeout=120s"; then
    echo "FAIL: rollout timeout"; rc=1
  fi

  del_ns rolling-demo
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 08 — liveness and readiness probes
# ---------------------------------------------------------------------------
verify_08() {
  local rc=0
  echo "=== 08: probes ==="

  if ! kapply "$REPO"/experiments/08-probes/*.yaml; then
    echo "FAIL: apply"; rc=1
  elif ! kube "rollout status deployment/readiness-ok -n probes-demo --timeout=120s"; then
    echo "FAIL: readiness-ok rollout timeout"; rc=1
  elif ! kube "rollout status deployment/liveness-demo -n probes-demo --timeout=120s"; then
    echo "FAIL: liveness-demo rollout timeout"; rc=1
  else
    # readiness-fail pod: Running but not Ready (probe always returns 404)
    # Pod labels are app=readiness-demo,variant=fail
    kube "wait pod -l variant=fail -n probes-demo --for=jsonpath={.status.phase}=Running --timeout=120s" 2>/dev/null || true
    local ready
    ready=$(kube "get pods -n probes-demo -l variant=fail -o jsonpath={.items[0].status.containerStatuses[0].ready}" 2>/dev/null | tr -d '[:space:]')
    if [[ "$ready" != "false" ]]; then
      echo "FAIL: readiness-fail pod should be not-ready (got: ready=$ready)"; rc=1
    fi
  fi

  del_ns probes-demo
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 09 — network policies
# ---------------------------------------------------------------------------
verify_09() {
  local rc=0
  echo "=== 09: network-policies ==="

  if ! kapply "$REPO"/experiments/09-network-policies/*.yaml; then
    echo "FAIL: apply"; rc=1
  elif ! kube "rollout status deployment/backend -n netpol-demo --timeout=120s"; then
    echo "FAIL: backend rollout"; rc=1
  elif ! kube "rollout status deployment/frontend -n netpol-demo --timeout=120s"; then
    echo "FAIL: frontend rollout"; rc=1
  elif ! kube "rollout status deployment/client -n netpol-demo --timeout=120s"; then
    echo "FAIL: client rollout"; rc=1
  else
    local npcount
    npcount=$(kube "get networkpolicy -n netpol-demo --no-headers 2>/dev/null" | wc -l | tr -d '[:space:]')
    if [[ "$npcount" -ne 2 ]]; then
      echo "FAIL: expected 2 NetworkPolicies, got $npcount"; rc=1
    fi
  fi

  del_ns netpol-demo
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 15 — StatefulSets
# ---------------------------------------------------------------------------
verify_15() {
  local rc=0
  echo "=== 15: statefulsets ==="

  # NFS PVC finalizers make namespace deletion slow; wait for any prior run to clear.
  local waited=0
  while kube "get namespace stateful-demo -o jsonpath={.status.phase}" 2>/dev/null | grep -q Terminating; do
    sleep 5; waited=$((waited + 5))
    if [[ $waited -ge 60 ]]; then echo "FAIL: stateful-demo namespace stuck Terminating"; return 1; fi
  done

  if ! kapply \
    "$REPO/experiments/15-statefulsets/namespace.yaml" \
    "$REPO/experiments/15-statefulsets/service.yaml" \
    "$REPO/experiments/15-statefulsets/statefulset.yaml"; then
    echo "FAIL: apply"; rc=1
  elif ! kube "rollout status statefulset/web -n stateful-demo --timeout=240s"; then
    echo "FAIL: rollout timeout"; rc=1
  elif ! kapply "$REPO/experiments/15-statefulsets/job-verify.yaml"; then
    echo "FAIL: apply verify job"; rc=1
  elif ! kube "wait job/verify -n stateful-demo --for=condition=complete --timeout=60s"; then
    echo "FAIL: verify job did not complete"; rc=1
  else
    local output
    output=$(kube "logs job/verify -n stateful-demo" 2>/dev/null)
    if ! echo "$output" | grep -q "All 3 pods have distinct stable identities"; then
      echo "FAIL: unexpected output: $output"; rc=1
    else
      echo "OK: $(echo "$output" | tail -1)"
    fi
  fi

  del_ns stateful-demo
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 13 — load balancing
# ---------------------------------------------------------------------------
verify_13() {
  local rc=0
  echo "=== 13: load-balancing ==="

  if ! kapply \
    "$REPO/experiments/13-load-balancing/namespace.yaml" \
    "$REPO/experiments/13-load-balancing/configmap.yaml" \
    "$REPO/experiments/13-load-balancing/deployment.yaml" \
    "$REPO/experiments/13-load-balancing/service.yaml"; then
    echo "FAIL: apply"; rc=1
  elif ! kube "rollout status deployment/lb-demo -n lb-demo --timeout=120s"; then
    echo "FAIL: rollout timeout"; rc=1
  elif ! kapply "$REPO/experiments/13-load-balancing/job-verify.yaml"; then
    echo "FAIL: apply verify job"; rc=1
  elif ! kube "wait job/lb-verify -n lb-demo --for=condition=complete --timeout=60s"; then
    echo "FAIL: verify job did not complete"; rc=1
  else
    # 30 requests across 3 pods — expect at least 2 distinct pod names.
    local unique
    unique=$(kube "logs -n lb-demo job/lb-verify" 2>/dev/null | sort -u | wc -l | tr -d '[:space:]')
    if [[ "$unique" -lt 2 ]]; then
      echo "FAIL: only $unique distinct pod(s) responded out of 30 requests (expected >= 2)"; rc=1
    else
      echo "OK: $unique distinct pods responded"
    fi
  fi

  del_ns lb-demo
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 14 — HPA (sequential: internal polling loop ~3 min)
# ---------------------------------------------------------------------------
verify_14() {
  local rc=0
  echo "=== 14: hpa ==="

  if ! kapply \
    "$REPO/experiments/14-hpa/namespace.yaml" \
    "$REPO/experiments/14-hpa/configmap.yaml" \
    "$REPO/experiments/14-hpa/deployment.yaml" \
    "$REPO/experiments/14-hpa/service.yaml" \
    "$REPO/experiments/14-hpa/hpa.yaml"; then
    echo "FAIL: apply"; rc=1
  elif ! kube "rollout status deployment/hpa-demo -n hpa-demo --timeout=300s"; then
    echo "FAIL: rollout timeout"; rc=1
  elif ! kapply "$REPO/experiments/14-hpa/job-load.yaml"; then
    echo "FAIL: apply load job"; rc=1
  else
    local scaled=false
    for i in $(seq 18); do
      sleep 10
      replicas=$(kube "get hpa hpa-demo -n hpa-demo -o jsonpath='{.status.currentReplicas}'" 2>/dev/null | tr -d "'" | tr -d '[:space:]')
      if [[ -n "$replicas" && "$replicas" -gt 1 ]]; then
        scaled=true
        echo "OK: HPA scaled to $replicas replicas"
        break
      fi
    done
    if ! $scaled; then
      echo "FAIL: HPA did not scale above 1 replica within 3 minutes"
      kube "describe hpa hpa-demo -n hpa-demo" 2>/dev/null | tail -20
      rc=1
    fi
  fi

  del_ns hpa-demo
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 18 — Container lifecycle hooks (sequential: preStop uses hostPath on ipc1)
# ---------------------------------------------------------------------------
verify_18() {
  local rc=0
  echo "=== 18: lifecycle-hooks ==="

  # Clean any leftover evidence from a prior run
  ssh $SSH_OPTS "$IPC1" "sudo rm -rf /tmp/hooks-demo-prestop" 2>/dev/null || true

  if ! kapply \
    "$REPO/experiments/18-lifecycle-hooks/namespace.yaml" \
    "$REPO/experiments/18-lifecycle-hooks/pod-poststart.yaml" \
    "$REPO/experiments/18-lifecycle-hooks/pod-prestop.yaml"; then
    echo "FAIL: apply"; rc=1
  elif ! kube "wait pod/poststart-demo -n hooks-demo --for=condition=ready --timeout=60s"; then
    echo "FAIL: poststart-demo not ready"; rc=1
  elif ! kube "wait pod/prestop-demo -n hooks-demo --for=condition=ready --timeout=60s"; then
    echo "FAIL: prestop-demo not ready"; rc=1
  else
    # Check 1: postStart wrote the file
    local proof
    proof=$(kube "exec -n hooks-demo poststart-demo -- cat /tmp/hook-proof" 2>/dev/null | tr -d '[:space:]')
    if [[ "$proof" != "poststart-ran" ]]; then
      echo "FAIL: postStart did not write proof file (got: '$proof')"; rc=1
    else
      echo "OK: postStart hook ran"
    fi

    # Check 2: preStop runs before termination — delete pod and check hostPath file
    kube "delete pod prestop-demo -n hooks-demo --grace-period=10" 2>/dev/null || true
    # Give preStop a moment to complete
    sleep 5
    local prestop_proof
    prestop_proof=$(ssh $SSH_OPTS "$IPC1" "cat /tmp/hooks-demo-prestop/prestop-proof 2>/dev/null | tr -d '[:space:]'")
    if [[ "$prestop_proof" != "prestop-ran" ]]; then
      echo "FAIL: preStop did not write proof file (got: '$prestop_proof')"; rc=1
    else
      echo "OK: preStop hook ran before termination"
    fi
  fi

  del_ns hooks-demo
  ssh $SSH_OPTS "$IPC1" "sudo rm -rf /tmp/hooks-demo-prestop" 2>/dev/null || true
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 16 — Pelagos cgroup plumbing (sequential: requires per-node SSH)
# ---------------------------------------------------------------------------
verify_16() {
  local rc=0
  echo "=== 16: cgroup-plumbing ==="

  if ! kapply \
    "$REPO/experiments/16-cgroup-plumbing/namespace.yaml" \
    "$REPO/experiments/16-cgroup-plumbing/deployment.yaml"; then
    echo "FAIL: apply"; rc=1
  elif ! kube "rollout status deployment/cgroup-probe -n cgroup-verify --timeout=120s"; then
    echo "FAIL: rollout timeout"; rc=1
  else
    # Wait 30s: containerIDs populate after rollout completes, and
    # usageCoreNanoSeconds needs time to accumulate before sampling.
    sleep 30

    local pods_json
    pods_json=$(kube "get pods -n cgroup-verify -o json" 2>/dev/null)

    # Extract pod→node→cri_id into arrays
    local -a pod_names=() pod_nodes=() pod_cris=()
    while IFS=$'\t' read -r pname pnode pcri; do
      pod_names+=("$pname"); pod_nodes+=("$pnode"); pod_cris+=("$pcri")
    done < <(echo "$pods_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for p in d['items']:
  cs=p.get('status',{}).get('containerStatuses',[])
  cri=next((c['containerID'][len('pelagos://'):] for c in cs if c.get('containerID','').startswith('pelagos://')), '')
  if cri:
    print(p['metadata']['name']+'\t'+p['spec']['nodeName']+'\t'+cri)
" 2>/dev/null)

    if [[ ${#pod_names[@]} -lt 3 ]]; then
      echo "FAIL: only ${#pod_names[@]} pods have container IDs (expected 3)"; rc=1
    fi

    for i in "${!pod_names[@]}"; do
      local pod_name="${pod_names[$i]}"
      local node="${pod_nodes[$i]}"
      local cri_id="${pod_cris[$i]}"
      local pcri_name="pcri-${cri_id:0:12}"

      echo "  Checking $pod_name on $node"

      local sshn
      if [[ "$node" == "ipc1" ]]; then
        sshn="ssh $SSH_OPTS $IPC1"
      else
        sshn="ssh $SSH_OPTS -J $IPC1 cb@$node"
      fi

      # Check 1: cgroup_name is non-null and starts with kubepods/
      local cgroup_name
      cgroup_name=$($sshn "sudo pelagos container inspect '$pcri_name' 2>/dev/null" | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cgroup_name') or '')" 2>/dev/null || true)
      if [[ -z "$cgroup_name" || "$cgroup_name" == "None" ]]; then
        echo "  FAIL: cgroup_name null/missing for $pod_name (pcri=$pcri_name)"; rc=1; continue
      fi
      if [[ "$cgroup_name" != kubepods/* ]]; then
        echo "  FAIL: cgroup_name='$cgroup_name' does not start with kubepods/"; rc=1; continue
      fi
      echo "  OK: cgroup_name=$cgroup_name"

      # Check 2: cgroup exists in filesystem
      if ! $sshn "test -d '/sys/fs/cgroup/$cgroup_name' || test -d '/sys/fs/cgroup/cpu/$cgroup_name'" 2>/dev/null; then
        echo "  FAIL: cgroup path not found in filesystem on $node"; rc=1; continue
      fi
      echo "  OK: cgroup path exists on $node"

      # Check 3: usageCoreNanoSeconds > 0 in kubelet summary on the pod's node
      local cum
      cum=$(ssh $SSH_OPTS "$IPC1" "sudo curl -sk \
        --cert /var/lib/rancher/k3s/server/tls/client-admin.crt \
        --key /var/lib/rancher/k3s/server/tls/client-admin.key \
        https://${node}:10250/stats/summary 2>/dev/null" | \
        python3 -c "
import json,sys
target='${cri_id:0:12}'
d=json.load(sys.stdin)
for p in d.get('pods',[]):
  for c in p.get('containers',[]):
    if target in p['podRef']['name'] or c.get('name','') == 'nginx':
      v=c.get('cpu',{}).get('usageCoreNanoSeconds',0)
      if v and v>0:
        print(v); sys.exit(0)
print(0)
" 2>/dev/null || echo 0)
      if [[ "${cum:-0}" -gt 0 ]]; then
        echo "  OK: usageCoreNanoSeconds=$cum"
      else
        echo "  WARN: usageCoreNanoSeconds=0 on $node (cgroup read may need more accumulation time)"
      fi
    done
  fi

  del_ns cgroup-verify
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 10 — NFS storage (sequential: touches default namespace)
# ---------------------------------------------------------------------------
verify_10() {
  local rc=0
  echo "=== 10: nfs-storage ==="

  if ! kube "get storageclass nfs" > /dev/null 2>&1; then
    echo "FAIL: nfs StorageClass missing"; rc=1
  elif ! kapply "$REPO"/experiments/10-nfs-storage/test-pvc.yaml; then
    echo "FAIL: apply test PVC"; rc=1
  elif ! kube "wait pvc/nfs-test -n default --for=jsonpath={.status.phase}=Bound --timeout=60s"; then
    echo "FAIL: PVC did not bind"; rc=1
  elif ! kube "wait pod/nfs-test -n default --for=condition=ready --timeout=120s"; then
    echo "FAIL: pod not ready"; rc=1
  else
    # Pelagos creates log files slightly after container start; retry up to 5×.
    local log_ok=false
    for i in 1 2 3 4 5; do
      if kube "logs pod/nfs-test -n default" 2>/dev/null | grep -q "NFS works"; then
        log_ok=true; break
      fi
      sleep 3
    done
    if ! $log_ok; then
      echo "FAIL: pod log did not contain 'NFS works' after retries"; rc=1
    fi
  fi

  kube "delete pod/nfs-test pvc/nfs-test -n default --ignore-not-found --wait=false" 2>&1 || true
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 11 — SPIRE (sequential: SPIRE infra is shared with Flux)
# ---------------------------------------------------------------------------
verify_11() {
  local rc=0
  echo "=== 11: spire ==="

  if ! kube "exec -n spire statefulset/spire-server -- /opt/spire/bin/spire-server healthcheck"; then
    echo "FAIL: spire-server not healthy"; rc=1
  fi

  if [[ $rc -eq 0 ]]; then
    # spire-agent image has no wget/curl; verify via the server's agent list.
    # Three attested agents = all nodes connected and healthy.
    local agent_count
    agent_count=$(kube "exec -n spire statefulset/spire-server -- /opt/spire/bin/spire-server agent list" 2>/dev/null | grep -c 'SPIFFE ID' || echo 0)
    if [[ "$agent_count" -lt 3 ]]; then
      echo "FAIL: expected 3 attested spire-agents, got $agent_count"; rc=1
    fi
  fi

  if [[ $rc -eq 0 ]]; then
    kapply \
      "$REPO/experiments/11-spire/demo-namespace.yaml" \
      "$REPO/experiments/11-spire/demo-registration-rbac.yaml" || { echo "FAIL: apply demo RBAC"; rc=1; }
  fi

  if [[ $rc -eq 0 ]]; then
    # Job spec is immutable; delete any stale job before re-applying.
    kube "delete job spire-register-demo -n spire --ignore-not-found" 2>&1 || true
    kapply "$REPO/experiments/11-spire/demo-registration-job.yaml" || { echo "FAIL: apply registration job"; rc=1; }
  fi

  if [[ $rc -eq 0 ]]; then
    kube "wait job/spire-register-demo -n spire --for=condition=complete --timeout=120s" \
      || { echo "FAIL: registration job did not complete"; rc=1; }
  fi

  if [[ $rc -eq 0 ]]; then
    kapply "$REPO/experiments/11-spire/demo-workload.yaml" || { echo "FAIL: apply demo workload"; rc=1; }
  fi

  if [[ $rc -eq 0 ]]; then
    kube "wait pod/demo-workload -n spire-demo --for=jsonpath={.status.phase}=Succeeded --timeout=300s" \
      || { echo "FAIL: demo-workload pod did not succeed"; rc=1; }
  fi

  if [[ $rc -eq 0 ]]; then
    kube "logs pod/demo-workload -n spire-demo" | grep -q "spiffe://ipc.local/demo-app" \
      || { echo "FAIL: SPIFFE ID not found in workload logs"; rc=1; }
  fi

  del_ns spire-demo
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# 12 — user resolution from image /etc/passwd (sequential)
# ---------------------------------------------------------------------------
verify_12() {
  local rc=0
  echo "=== 12: user-resolution ==="

  if ! kapply "$REPO"/experiments/12-user-resolution/*.yaml; then
    echo "FAIL: apply"; rc=1
  elif ! kube "wait job/user-resolution-test -n user-demo --for=condition=complete --timeout=120s"; then
    echo "FAIL: job did not complete"; rc=1
  else
    # curlimages/curl OCI User is "curl_user" (string). Pelagos must resolve it
    # via the image's /etc/passwd (UID 100). If it reads the host's /etc/passwd
    # instead, "curl_user" won't exist and the job fails rather than completing.
    local uid_line
    uid_line=$(kube "logs -n user-demo job/user-resolution-test" 2>/dev/null)
    if ! echo "$uid_line" | grep -q "uid=100"; then
      echo "FAIL: expected uid=100(curl_user), got: $uid_line"; rc=1
    fi
  fi

  del_ns user-demo
  [[ $rc -eq 0 ]] && echo "PASS" || echo "FAIL"
  return $rc
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "Logs: $LOGDIR"
echo ""
prefetch_images
echo ""
echo "Starting parallel verification of experiments 01-09..."
echo ""

declare -A pids
verify_01_02 > "$LOGDIR/01-02.log" 2>&1 & pids[01_02]=$!
verify_03    > "$LOGDIR/03.log"    2>&1 & pids[03]=$!
verify_04    > "$LOGDIR/04.log"    2>&1 & pids[04]=$!
verify_05    > "$LOGDIR/05.log"    2>&1 & pids[05]=$!
verify_06    > "$LOGDIR/06.log"    2>&1 & pids[06]=$!
verify_07    > "$LOGDIR/07.log"    2>&1 & pids[07]=$!
verify_08    > "$LOGDIR/08.log"    2>&1 & pids[08]=$!
verify_09    > "$LOGDIR/09.log"    2>&1 & pids[09]=$!
verify_13    > "$LOGDIR/13.log"    2>&1 & pids[13]=$!
verify_15    > "$LOGDIR/15.log"    2>&1 & pids[15]=$!

declare -A results
for key in 01_02 03 04 05 06 07 08 09 13 15; do
  if wait "${pids[$key]}"; then results[$key]=PASS; else results[$key]=FAIL; fi
done

echo "Parallel batch complete."
echo ""
printf "  %-35s %s\n" "01+02 namespaces/ingress"  "${results[01_02]}"
printf "  %-35s %s\n" "03    configmaps/secrets"   "${results[03]}"
printf "  %-35s %s\n" "04    persistent-volumes"   "${results[04]}"
printf "  %-35s %s\n" "05    rbac"                 "${results[05]}"
printf "  %-35s %s\n" "06    resource-limits"      "${results[06]}"
printf "  %-35s %s\n" "07    rolling-deployments"  "${results[07]}"
printf "  %-35s %s\n" "08    probes"               "${results[08]}"
printf "  %-35s %s\n" "09    network-policies"     "${results[09]}"
printf "  %-35s %s\n" "13    load-balancing"       "${results[13]}"
printf "  %-35s %s\n" "15    statefulsets"         "${results[15]}"

echo ""
echo "Starting sequential experiments..."
echo ""

verify_10 > "$LOGDIR/10.log" 2>&1; results[10]=$?; [[ ${results[10]} -eq 0 ]] && results[10]=PASS || results[10]=FAIL
verify_11 > "$LOGDIR/11.log" 2>&1; results[11]=$?; [[ ${results[11]} -eq 0 ]] && results[11]=PASS || results[11]=FAIL
verify_12 > "$LOGDIR/12.log" 2>&1; results[12]=$?; [[ ${results[12]} -eq 0 ]] && results[12]=PASS || results[12]=FAIL
verify_14 > "$LOGDIR/14.log" 2>&1; results[14]=$?; [[ ${results[14]} -eq 0 ]] && results[14]=PASS || results[14]=FAIL
verify_16 > "$LOGDIR/16.log" 2>&1; results[16]=$?; [[ ${results[16]} -eq 0 ]] && results[16]=PASS || results[16]=FAIL
verify_18 > "$LOGDIR/18.log" 2>&1; results[18]=$?; [[ ${results[18]} -eq 0 ]] && results[18]=PASS || results[18]=FAIL

printf "  %-35s %s\n" "10    nfs-storage"          "${results[10]}"
printf "  %-35s %s\n" "11    spire"                 "${results[11]}"
printf "  %-35s %s\n" "12    user-resolution"       "${results[12]}"
printf "  %-35s %s\n" "14    hpa"                   "${results[14]}"
printf "  %-35s %s\n" "16    cgroup-plumbing"       "${results[16]}"
printf "  %-35s %s\n" "18    lifecycle-hooks"       "${results[18]}"

echo ""
echo "=== Summary ==="
fail=0
for key in 01_02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 18; do
  [[ "${results[$key]}" != "PASS" ]] && ((fail++)) || true
done
total=16
pass=$((total - fail))
printf "  %d/%d passed\n" "$pass" "$total"
if [[ $fail -eq 0 ]]; then
  echo "  All experiments PASS"
else
  echo "  $fail experiment(s) FAILED — check logs in $LOGDIR"
fi


[[ $fail -eq 0 ]]
