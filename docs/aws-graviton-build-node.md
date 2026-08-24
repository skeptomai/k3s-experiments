# AWS Graviton Build Node

An arm64 k3s worker running on AWS EC2 (Graviton4, `c8g.2xlarge`), joined to
the cluster to build Pelagos and other arm64 projects without needing local
arm64 hardware. See [issue #19](https://github.com/skeptomai/k3s-experiments/issues/19)
for the original design discussion and
[issue #20](https://github.com/skeptomai/k3s-experiments/issues/20) for the
networking rework described below. This doc covers the AWS node
specifically, not a repeat of the general cluster docs.

## Why this exists

Building arm64 binaries locally had no good option when this was built: a new
Mac mini/Studio was 2-3 months out (Apple RAM shortage), and dedicated arm64
hardware (Ampere Altra dev boards, a second DGX Spark) cost the same as what
we were avoiding or served a different job (LLM inference, not compiling).
Graviton4 on-demand compute is cheap and available immediately, and joining it
to the existing k3s cluster as a real (if cloud-hosted) worker means build
Jobs schedule onto it exactly like any other node, rather than needing a
bespoke one-off box managed by hand.

## Architecture

- **Instance**: `c8g.2xlarge` (8 vCPU/16GB), `us-west-2`, default VPC. Security
  group allows one inbound rule (UDP 51820, the WireGuard tunnel — see
  Networking below); SSH/admin access is still Tailscale-only, no inbound
  needed for that.
- **Lifecycle**: stop/start, not terminate/recreate. The EBS root volume
  persists the toolchain, build caches, and joined node identity across
  sessions. Compute cost is $0 while stopped (~$8/mo EBS storage, plus
  ~$3.60/mo for the Elastic IP which is billed regardless of attachment
  state). Managed by `scripts/aws-build-node.sh {start|stop|status}`.
- **k3s role**: agent only, never control-plane/etcd. `K3S_URL` points at
  ipc4 directly (`https://ipc4.taildd208.ts.net:6443`), not the kube-vip VIP
  — the VIP is LAN-only (floating L2/ARP address) and unreachable from a
  cloud node even with the WireGuard tunnel. This makes this one agent's
  control-plane connectivity non-HA (single point of failure on ipc4),
  consistent with how the `default` kubeconfig context already works.
- **CRI**: Pelagos (not stock containerd), for fleet consistency — same
  `pelagos_cri` Prometheus scrape pattern as ipc4-9.
- **Isolation**: tainted `cloud=aws:NoSchedule`. Only pods with a matching
  toleration schedule there — nothing lands on it by accident. Target it via
  the automatic `kubernetes.io/arch: arm64` label plus the toleration, not by
  hostname.
- **Node-class label**: `node-class=cloud-arm64` (see
  `config/k3s-agent-cloud.yaml`), distinct from ipc7-9's `fastest` label.

## Networking: site-to-site WireGuard peering (k3s-experiments#20)

**First attempt (retired): Tailscale subnet routing.** The original design
had ipc4 advertise `192.168.88.0/24` as a Tailscale subnet route and the AWS
node accept it, giving the AWS node a relayed path to LAN node IPs. This
looked like it worked (raw `ping` between the AWS node and any LAN IP
succeeded), but real pod-to-pod traffic through Cilium's vxlan overlay
didn't — some UDP:8472 traffic silently died on the relayed hop while ICMP
survived it fine. Root cause: the AWS node was k3s-registered by its
**Tailscale IP**, while every LAN node is registered by **LAN IP** — traffic
in one direction went direct peer-to-peer over Tailscale, traffic in the
other got relayed through ipc4, and that asymmetry broke the vxlan mesh
Cilium assumes is uniformly reachable. Full write-up of the debugging in
issue #20.

**Current design: real network peering.** A site-to-site WireGuard tunnel
connects the home MikroTik router directly to the AWS instance, giving the
AWS node a single, symmetric, routable identity — same as every LAN node
already has with respect to each other:

- **Direction**: the MikroTik **initiates** the handshake to a fixed **AWS
  Elastic IP** (`44.240.126.103`). This sidesteps the home WAN's dynamic
  public IP entirely — AWS never needs to track it, the MikroTik just
  always dials the same address.
- **Tunnel link**: dedicated `/30`, `10.100.100.0/30` — MikroTik
  `10.100.100.1`, AWS `10.100.100.2`. WireGuard config lives at
  `/etc/wireguard/wg0.conf` on the instance (persists on the root EBS
  volume, `systemctl enable --now wg-quick@wg0`) and as the `wg-aws`
  interface on the MikroTik.
- **Routing** — only two routes, no per-node changes needed anywhere:
  - MikroTik: `172.31.0.0/16` (the VPC) via `wg-aws`. Every LAN host already
    defaults through the MikroTik, so this alone makes the whole VPC
    reachable LAN-wide.
  - AWS instance: `192.168.88.0/24` via `wg0` (peer `10.100.100.1`).
- **k3s `node-ip`**: the AWS node is now registered by its **VPC private IP**
  (`172.31.47.167`, set via `node-ip:` in `config/k3s-agent-cloud.yaml`), not
  its Tailscale IP. This is what actually fixed Cilium — both directions are
  now symmetric routed IP traffic through the same tunnel, no more
  direct-vs-relay split. Verified with real pod-to-pod `ping`/`nc` across the
  boundary, not just host-level connectivity, including a full
  `aws-build-node.sh stop` → `start` cycle to confirm the tunnel self-heals
  with zero manual steps (WireGuard has no connection state to rebuild —
  the MikroTik's periodic keepalive just succeeds again once the instance's
  `wg0` is listening).
- **Security group**: inbound UDP 51820 from `0.0.0.0/0` — standard/safe for
  WireGuard specifically, since it never responds to an unauthenticated
  handshake, so it's invisible to scanners regardless of source.
- **Tailscale stays installed**, demoted out of the cluster-networking path
  entirely — `--accept-routes` is disabled on the AWS node so its own
  routing table doesn't compete with the WireGuard route (Tailscale's policy
  routing table otherwise outranks the main table and silently wins, which
  is exactly the bug that took the longest to track down — see #20). It's
  kept purely for convenient SSH/admin access from anywhere, not just when
  on the home LAN.
- **The original Tailscale subnet-route has been rolled back** on ipc4 (both
  `advertisedRoutes` and `enabledRoutes` confirmed empty via the Tailscale
  API) — it served no purpose once the tunnel existed and was unnecessary
  standing LAN exposure.

**One-time MikroTik config** (not in git — router state, documented here so
it's not tribal knowledge):
```
/interface wireguard add name=wg-aws listen-port=51820
/ip address add address=10.100.100.1/30 interface=wg-aws
/interface wireguard peers add interface=wg-aws \
    public-key="<AWS instance's wg0 public key>" \
    endpoint-address=44.240.126.103 endpoint-port=51820 \
    allowed-address=172.31.0.0/16,10.100.100.0/30 persistent-keepalive=25s
/ip route add dst-address=172.31.0.0/16 gateway=wg-aws
```

### MTU

Measured (both directions, `ping -M do` sweep) during the original
Tailscale-relay design: **1280 bytes** real path MTU — the standard
Tailscale/WireGuard ceiling, and Cilium's auto-detected MTU already matched
it cluster-wide (picked up from `tailscale0`, present on every node). The
new direct WireGuard tunnel carries the same ~1280-byte ceiling (WireGuard's
standard overhead), and real pod-to-pod traffic (not just ICMP) has been
verified working across it — if MTU-related fragmentation ever surfaces, the
fix is pinning Cilium's `MTU` Helm value explicitly rather than relying on
auto-detection.

## Bootstrap mechanics (how a rebuild works)

If the instance is ever replaced (not just stopped/started):

1. `cd infra/aws-graviton-build && terraform apply` — recreates the instance
   (keeps the same Elastic IP association); cloud-init installs Tailscale
   only (sets OS hostname, joins the tailnet).
2. Re-run the WireGuard setup on the fresh instance (`apt install wireguard`,
   regenerate keypair, write `/etc/wireguard/wg0.conf`,
   `systemctl enable --now wg-quick@wg0`) — the MikroTik side doesn't need
   to change unless the new instance's wg0 public key differs, in which case
   update the peer's `public-key=` on the MikroTik.
3. `scripts/join-cloud-agent.sh aws-graviton-build ubuntu` — fetches the join
   token/version from ipc4, installs k3s agent with `--node-name`/
   `--node-taint` set explicitly (node-ip is NOT set here — see the gotcha
   below).
4. `scripts/install-pelagos.sh aws-graviton-build` — installs the arm64
   Pelagos release (arch auto-detected via `uname -m` on the target), swaps
   the k3s config (including `node-ip: 172.31.47.167`) to point at the
   Pelagos CRI socket, restarts services.
5. `scripts/label-nodes.sh` — reapplies `node-class=cloud-arm64` (also baked
   into `config/k3s-agent-cloud.yaml`'s `node-label`, so it survives a k3s
   reinstall too, same pattern as ipc4-9).
6. Delete and let recreate the Cilium pods on the node
   (`kubectl delete pod -n cilium -l k8s-app=cilium --field-selector
   spec.nodeName=aws-graviton-build`) so they pick up the new node identity
   cleanly rather than carrying over stale state from a mid-flight CRI or
   node-ip swap.

**Known gotchas**:

- cloud-init's `hostname:` field must match the intended k3s node name and
  the Tailscale `--hostname` flag — k3s defaults to the OS hostname for the
  node name, and Canonical's Ubuntu AMI otherwise leaves it as the
  AWS-assigned `ip-x-x-x-x`. This is set in
  `infra/aws-graviton-build/templates/user-data.yaml.tftpl` and also passed
  explicitly via `--node-name` in `join-cloud-agent.sh` as defense-in-depth.
- **`node-ip` must live in exactly one place.** k3s merges an exec-arg
  `--node-ip` with config.yaml's `node-ip:` rather than one overriding the
  other — if both are set (even to the same value), kubelet refuses to start
  with `bad --node-ip "a,b": must contain either a single IP or a
  dual-stack pair of IPs`. `join-cloud-agent.sh` deliberately does not pass
  `--node-ip` at all; `config/k3s-agent-cloud.yaml`'s `node-ip:` is the sole
  source of truth.
- **Tailscale's policy routing table outranks the main table.** If
  `--accept-routes` is ever re-enabled on the AWS node with a LAN subnet
  route still advertised anywhere, Tailscale's routing table (priority 5270)
  wins over a manually-added WireGuard route in the main table (priority
  32766) for the same destination — traffic silently reverts to the old
  relay path with no error, no log, nothing. Confirm with
  `ip route get 192.168.88.63` (should show `dev wg0`, not `dev tailscale0`)
  if cross-boundary connectivity ever regresses.

## Usage

**Start/stop**: `scripts/aws-build-node.sh start` / `stop` / `status`.

**Submit a build Job**: target the node via `nodeSelector` on
`kubernetes.io/arch: arm64` plus a toleration for `cloud=aws:NoSchedule` —
see `scripts/cluster-scheduler/build-job.yaml` or
`experiments/29-pelagos-build/build-job.yaml` for the existing pattern
(those pin to a specific LAN hostname; the arm64 job should target the arch
label instead so it generalizes to any future arm64 node).

```yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64
      tolerations:
        - key: cloud
          operator: Equal
          value: aws
          effect: NoSchedule
```

Remember to `scripts/aws-build-node.sh start` first if it's stopped — the
node won't be Ready (and the Job will sit Pending) until the instance is
running and Tailscale/k3s have come back up (~30-60s after start).
