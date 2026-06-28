# Runbook: Promote ipc1-3 to an HA Control Plane (embedded etcd)

Convert the cluster from a **single k3s server (ipc1, SQLite)** to a **3-node HA
control plane (ipc1-3, embedded etcd)**. This gives the idle slow nodes (ipc2/ipc3)
a fitting job, removes the single-point-of-failure datastore, and is a prerequisite
for using this cluster as a robust Kamaji management cluster (see `kamaji-on-k3s.md`).

**Workloads stay on ipc4-6 throughout** — ipc1-3 remain control-plane-only via taints.

> **✅ EXECUTED 2026-06-28.** Ran end-to-end successfully. ipc1 migrated
> SQLite→etcd in place (`state.db.migrated`); ipc2 then ipc3 reprovisioned in-place
> (agent-uninstall → delete node + node-password secret → reinstall as server
> pinned to `v1.35.5+k3s1`). Final: 3× `control-plane,etcd` Ready, 3 workers,
> pelagos CRI intact, HA failover verified (stopped ipc1, API still served via
> ipc2 on 2/3 quorum). Stale daemonset pods on ipc2 (left by the node
> delete/recreate) were cleared so the DaemonSets recreated them fresh.
> **Follow-ups:**
> - ✅ **Reinstall/PXE path made role-aware (2026-06-28).** A reinstall of ipc2/ipc3
>   now re-registers them as **servers**, not agents. Roles are centralized in
>   `scripts/lib/node-roles.sh`; `reinstall-nodes.sh` dispatches servers to the new
>   `scripts/join-server.sh` and agents to `upgrade-agents.sh`; `install-pelagos.sh`
>   is role-aware (server config + `k3s` unit on ipc1-3, injecting the join token for
>   ipc2/ipc3; agent config + `k3s-agent` unit on ipc4-6); `upgrade-server.sh` does a
>   rolling quorum-safe upgrade of all three servers. See "Reinstall path" below.
> - ✅ **kube-vip** HA external API endpoint **deployed 2026-06-28** — floating VIP
>   `192.168.88.58` (`k8s-api.home.skeptomai.com`) across ipc1-3; added an additive
>   `ipc-vip` kubeconfig context (default stays tailnet). Required pelagos v0.65.40
>   (hostNetwork fix #410). Full detail + the apiserver-health failover caveat in
>   **`kube-vip.md`**.

## Pre-flight facts (audited 2026-06-28)

- **Datastore today:** SQLite/kine on ipc1 only (`/var/lib/rancher/k3s/server/db/state.db`).
  No etcd anywhere. ipc2/ipc3 are agents.
- **Hardware:** ipc1-3 are Pentium G5400T / 30 GiB / **SATA SSD** — fine for etcd
  (light CPU/RAM; fsync-tolerant disk). See `hardware-inventory.md`.
- **Quorum math:** 3 etcd members tolerate **exactly one** node down. Two down →
  API read-only. Acceptable for homelab.
- **Taints today:**
  - `control-plane:NoSchedule` — persisted in `config/k3s-server.yaml` (applied at
    registration, survives reinstall).
  - `slow:NoSchedule` — **live `kubectl taint` only; NOT in any config/manifest.**
    It will be lost on a PXE reinstall. This runbook persists it (see Step 4).

## Strategy

k3s **cannot hot-promote an agent to a server.** ipc2/ipc3 must be reprovisioned as
servers. PXE reinstall is the normal flow here (`ipc1-upgrade-runbook.md`,
`scripts/reinstall-nodes.sh`), so we lean on it. ipc1 is converted in place by adding
`--cluster-init`, which migrates its SQLite data into embedded etcd on restart.

Order: **ipc1 first** (become the etcd cluster-init member), then **ipc2, then ipc3**
join as servers, one at a time, verifying quorum after each.

---

## Step 0 — Backup (mandatory)

```bash
bash scripts/backup-ipc1.sh pre-ha-etcd-$(date +%Y%m%d)
```
Confirm the listing includes `server/db`, `server/tls`, and `server/token` before
proceeding. This is the rollback anchor — the SQLite migration is one-way in
practice; if anything goes wrong, restore from here.

> While ipc1 is briefly down, use **ipc2 as the SSH jump** (ipc1 can't jump through
> itself). nazgul/PXE remain reachable.

---

## Step 1 — Convert ipc1 to embedded etcd (`--cluster-init`)

Add `cluster-init` to ipc1's server config and restart.

`config/k3s-server.yaml` (ipc1) — add:
```yaml
cluster-init: true
```

Apply:
```bash
# deploy the updated config, then restart k3s on ipc1
bash scripts/deploy-*configs.sh        # or scp config/k3s-server.yaml ipc1:/etc/rancher/k3s/config.yaml
ssh ipc1 'sudo systemctl restart k3s'
```

**Verify the SQLite→etcd migration succeeded before touching anything else:**
```bash
ssh ipc1 'sudo ls /var/lib/rancher/k3s/server/db/etcd/member/'   # should now exist
ssh ipc1 'sudo k3s etcd-snapshot ls' 2>/dev/null || true
kubectl get nodes        # ipc1 Ready, cluster still serving
kubectl get --raw /healthz
```
If etcd did not come up, **stop** and restore from the Step 0 backup.

---

## Step 2 — Capture the server join token

```bash
TOKEN=$(ssh ipc1 'sudo cat /var/lib/rancher/k3s/server/token')
echo "$TOKEN"   # needed for ipc2/ipc3 server configs
```

---

## Step 3 — Reprovision ipc2 as a server

ipc2/ipc3 currently use `config/k3s-agent.yaml`. They need a **server** config that
joins ipc1's etcd. Create `config/k3s-server-join.yaml` (shared by ipc2/ipc3):

```yaml
container-runtime-endpoint: "unix:///run/pelagos/cri.sock"
flannel-backend: wireguard-native
disable: local-storage
server: "https://192.168.88.53:6443"     # ipc1
token: "<SERVER_TOKEN_FROM_STEP_2>"
node-taint:
  - "node-role.kubernetes.io/control-plane:NoSchedule"
  - "slow:NoSchedule"                     # persist the slow taint (was live-only)
```

Reprovision ipc2 as a server (PXE reinstall path, or in place):

**In-place (faster):**
```bash
ssh ipc2 'sudo /usr/local/bin/k3s-agent-uninstall.sh'   # remove agent
# install as server joining ipc1's etcd:
ssh ipc2 'curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server" \
  K3S_CONFIG_FILE=/etc/rancher/k3s/config.yaml sh -'     # after placing config above
```
(or use `scripts/reinstall-nodes.sh` for the PXE path, with the server config.)

**Verify quorum is now 2 members:**
```bash
kubectl get nodes -o wide          # ipc2 now Ready, role control-plane
ssh ipc1 'sudo k3s kubectl get nodes -l node-role.kubernetes.io/control-plane'
# etcd member list:
ssh ipc1 'sudo ETCDCTL_API=3 k3s etcd-snapshot ls' 2>/dev/null || true
```

> A 2-member etcd has **no fault tolerance** (quorum=2). Move to Step 4 promptly to
> reach the fault-tolerant 3.

---

## Step 4 — Reprovision ipc3 as a server

Identical to Step 3, using the same `config/k3s-server-join.yaml` (server URL still
points at ipc1):

```bash
ssh ipc3 'sudo /usr/local/bin/k3s-agent-uninstall.sh'
ssh ipc3 'curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server" \
  K3S_CONFIG_FILE=/etc/rancher/k3s/config.yaml sh -'
```

---

## Step 5 — Verify HA quorum

```bash
kubectl get nodes -o wide
# Expect ipc1, ipc2, ipc3 all ROLES=control-plane, all Ready.

# 3 healthy etcd members:
ssh ipc1 'sudo k3s kubectl get nodes \
  -l node-role.kubernetes.io/control-plane \
  -o custom-columns=NODE:.metadata.name,TAINTS:.spec.taints[*].key'

# Confirm workloads still pinned off ipc1-3:
kubectl get pods -A -o wide | grep -E 'ipc1|ipc2|ipc3' | grep -v kube-system
# (should be empty/only taint-tolerating system pods)

# API HA smoke test — kill k3s on ipc1, confirm cluster still serves via ipc2/3:
ssh ipc1 'sudo systemctl stop k3s'
kubectl --server https://192.168.88.52:6443 get nodes    # via ipc2
ssh ipc1 'sudo systemctl start k3s'
```

---

## Step 6 — Persist the config in Git

- ✅ Commit `config/k3s-server.yaml` (now with `cluster-init: true`) and the new
  `config/k3s-server-join.yaml`.
- ✅ Update `node-scheduling.md`: ipc2/ipc3 are now **control-plane** nodes; document
  the now-persisted `slow:NoSchedule` taint (previously live-only).
- ✅ Make the reinstall/PXE path re-register ipc2/ipc3 as **servers** — see
  "Reinstall path (role-aware)" below.

---

## Rollback

If etcd is unhealthy after Step 1 (before reprovisioning ipc2/3):
```bash
ssh ipc1 'sudo systemctl stop k3s'
# restore SQLite state from the Step 0 backup, remove cluster-init from config,
# remove /var/lib/rancher/k3s/server/db/etcd, restart k3s
```
Once ipc2/ipc3 have joined etcd, rollback means restoring the snapshot to a single
member and re-initializing — so **get Step 1 verification right before proceeding.**

## Caveats

- **Quorum = tolerate 1 failure.** During reprovisioning you pass through a 1- and
  2-member window with reduced/zero tolerance — do Steps 3-4 back to back, not days apart.
- **etcd defragmentation / snapshots:** k3s auto-snapshots etcd; confirm the schedule
  (`--etcd-snapshot-schedule-cron`) and that snapshots land somewhere durable (nazgul).
- **pelagos CRI** is unchanged — all three keep `unix:///run/pelagos/cri.sock`.

---

## Reinstall path (role-aware, since 2026-06-28)

The cluster-management scripts now encode the HA topology so a PXE reinstall of a
control-plane node re-registers it as a **server**, not an agent.

- **`scripts/lib/node-roles.sh`** — single source of truth: `SERVER_NODES=(ipc1 ipc2
  ipc3)`, `AGENT_NODES=(ipc4 ipc5 ipc6)`, `CLUSTER_INIT_NODE=ipc1`, plus
  `is_server_node` / `k3s_role` / `k3s_service` helpers. Other scripts source it.
- **`scripts/join-server.sh <ipc2|ipc3>`** — joins a freshly-reinstalled node to
  ipc1's etcd as a server: pins k3s to the seed's version, fetches the SERVER token,
  clears the stale node object + node-password secret, writes a `server:`+`token:`
  config, installs with `INSTALL_K3S_EXEC=server`, then runs `install-pelagos.sh`.
- **`scripts/reinstall-nodes.sh`** — dispatches the rejoin by role
  (`is_server_node` → `join-server.sh`, else `upgrade-agents.sh`).
- **`scripts/install-pelagos.sh`** — role-aware: deploys `k3s-server.yaml` on the
  seed, `k3s-server-join.yaml` (token injected) on ipc2/ipc3 with the `k3s` unit, and
  `k3s-agent.yaml` with the `k3s-agent` unit on workers. (Previously it always wrote
  the agent config + restarted `k3s-agent` for any non-ipc1 node — which would have
  clobbered a server node.)
- **`scripts/upgrade-agents.sh`** — defaults to `AGENT_NODES`; refuses server nodes.
- **`scripts/upgrade-server.sh`** — rolling, one-at-a-time, quorum-safe upgrade of
  ipc1-3.

**Note — reinstalling a server node:** etcd is replicated, so ipc2/ipc3 *can* be
reinstalled (unlike ipc1, the seed). `join-server.sh` deletes the node object first,
which makes k3s remove the old etcd member; the node then re-joins as a fresh member.
After a server reinstall, verify membership:
`kubectl get nodes -l node-role.kubernetes.io/etcd` should list exactly ipc1/ipc2/ipc3.

**Testing status:** scripts are `bash -n` syntax-clean and the role lib +
config-rendering were dry-run verified. The destructive end-to-end reinstall was
**not** live-run (it reboots/wipes a node); validate on the next real reinstall.
