# Cilium CNI

Cilium 1.19.6 replaced Flannel (wireguard-native) as the CNI on 2026-08-01.
Flux-managed via `clusters/ipc/` (HelmRelease in the `cilium` namespace).

## k3s config (all nodes)

Flannel is disabled cluster-wide:

```yaml
# /etc/rancher/k3s/config.yaml (server and agent)
flannel-backend: none
network-policy: false   # k3s built-in enforcer off; Cilium enforces instead
```

## Helm values (revision 7, no workarounds)

```
cni.confPath        = /var/lib/rancher/k3s/agent/etc/cni/net.d
cni.binPath         = /var/lib/rancher/k3s/data/current/bin
cni.exclusive       = true
ipam.operator.clusterPoolIPv4PodCIDRList = {10.42.0.0/16}
kubeProxyReplacement = false     # k3s embedded kube-proxy still handles ClusterIP/NodePort
cgroup.autoMount.enabled = false
cgroup.hostRoot      = /sys/fs/cgroup
k8sServiceHost       = 192.168.88.58   # kube-vip VIP
k8sServicePort       = 6443
operator.replicas    = 2
```

`kubeProxyReplacement=false` means Cilium handles **NetworkPolicy enforcement** via
BPF but leaves ClusterIP/NodePort DNAT to k3s's embedded kube-proxy (iptables).

## Pelagos workarounds required

Two Pelagos bugs had to be fixed before Cilium ran cleanly:

| Pelagos issue | Symptom | Fixed in |
|---------------|---------|----------|
| #484 | EROFS on `/var/run` hostPath → cilium-envoy CrashLoopBackOff | v0.65.69 |
| #483 | `$BIN_PATH` not reaching container → apply-sysctl-overwrites init CrashLoopBackOff | v0.65.70 |
| #492 | Duplicate `/sys/fs/bpf` mount (shared-propagated) → cilium-agent CrashLoopBackOff | v0.65.73 |

## Kubelet health probe quirk — READ THIS BEFORE ADDING NetworkPolicies

**Symptom:** pods in a namespace with a k8s NetworkPolicy fail liveness/readiness
probes with `context deadline exceeded (Client.Timeout exceeded while awaiting headers)`.
The pods work fine from inside the cluster but kubelet can't reach them.

**Root cause:** Cilium assigns `cilium_host` IPs (10.42.x.x — the per-node virtual
gateway address) the `world` security identity at the BPF layer, even though the
ipcache correctly maps them to `reserved:host` (identity 1). The BPF code path for
local host→pod traffic uses `world`, not `host`.

This only matters when a namespace has at least one k8s NetworkPolicy — Cilium's
default mode allows all traffic in policy-free namespaces. Once a policy exists in a
namespace, Cilium enforces default-deny for selected pods, and kubelet probes (sourced
from the `cilium_host` IP, classified as `world`) are blocked.

**Fix:** add a `CiliumNetworkPolicy` to the namespace that explicitly allows `world`
ingress on the health-probe ports:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-kubelet-probes
  namespace: <your-namespace>
spec:
  endpointSelector: {}
  ingress:
  - fromEntities:
    - host          # belt: covers any future fix in Cilium
  - fromEntities:
    - world
    toPorts:
    - ports:
      - port: "<liveness-port>"
        protocol: TCP
      - port: "<readiness-port>"
        protocol: TCP
```

**Currently patched namespaces:**

| Namespace | Ports | Policy file |
|-----------|-------|-------------|
| flux-system | 9440 (health), 9090 (source-controller storage), 9443 (notification webhook) | `manifests/cilium-netpols/flux-system-allow-kubelet-probes.yaml` |

`manifests/cilium-netpols/` is Flux-managed (`clusters/ipc/cilium-netpols.yaml`) and
reconciles automatically on rebuild.

**Rule for the future:** any namespace you add a k8s NetworkPolicy to needs a
corresponding `CiliumNetworkPolicy allow-kubelet-probes` entry in
`manifests/cilium-netpols/` before the pods will pass health checks.

## Diagnosing probe failures

```bash
# 1. Find the Cilium pod on the same node as the failing pod
kubectl get pod -n <ns> <pod> -o jsonpath='{.spec.nodeName}'
CILIUM_POD=$(kubectl get pod -n cilium -l app.kubernetes.io/name=cilium-agent \
  --field-selector spec.nodeName=<node> -o jsonpath='{.items[0].metadata.name}')

# 2. Find the endpoint ID
kubectl exec -n cilium $CILIUM_POD -- cilium endpoint list | grep <pod-ip>

# 3. Watch for drops while the probe fires
kubectl exec -n cilium $CILIUM_POD -- \
  cilium-dbg monitor --type drop --related-to <endpoint-id>

# 4. Confirm the drop shows "identity world->..." (not "host->...")
# That confirms the cilium_host misclassification — apply the CNP above.
```

## Verifying NetworkPolicy enforcement

Experiment 09 (`experiments/09-network-policies/`) tests enforcement end-to-end:

```bash
kubectl apply -f experiments/09-network-policies/

# client → backend should be BLOCKED (wget exits 1)
kubectl exec -n netpol-demo deploy/client -- \
  wget -qO- --timeout=5 http://10.43.x.x  # backend ClusterIP

# frontend → backend should be ALLOWED (nginx 200)
kubectl exec -n netpol-demo deploy/frontend -- \
  wget -qO- --timeout=5 http://10.43.x.x
```

Both directions verified working on v0.65.73 (2026-08-01).

## Rebuild checklist

On a fresh cluster, Flux bootstrapping brings back Cilium automatically once the
HelmRelease in `clusters/ipc/` reconciles. The kubelet-probe CNPs in
`manifests/cilium-netpols/` also reconcile automatically.

Manual steps that are **not** automated:

1. k3s server/agent configs (`config/`) must have `flannel-backend: none` and
   `network-policy: false` before the node joins — done by `install-pelagos.sh`.
2. Pelagos v0.65.73+ required (earlier versions crash Cilium — see table above).
3. If you add a new namespace with NetworkPolicies, add a
   `CiliumNetworkPolicy allow-kubelet-probes` to `manifests/cilium-netpols/`.
