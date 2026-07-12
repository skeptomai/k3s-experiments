# Migrate the control plane off the Pentiums → 6-node all-Elite-Mini cluster

Retire the three Pentium Gold control-plane nodes (**ipc1/ipc2/ipc3**) and move the
control plane onto three HP Elite Minis. Driver is **physical** (the Pentiums are
big/fanless/heavy and won't rack) — not performance. Functionally the Pentiums
carry **no workload** (they're tainted `control-plane:NoSchedule` + `slow:NoSchedule`),
so the only thing to relocate is **etcd + the API server**.

## Target topology

| Nodes | Role | Notes |
|---|---|---|
| **ipc4, ipc5, ipc6** | server + etcd + **worker** (co-located, **un-tainted**) | 32 GB; already the "infra" nodes (build jobs, cluster-deploy key) |
| **ipc7, ipc8, ipc9** | agent (worker) | 32 GB |
| ~~ipc1, ipc2, ipc3~~ | **removed** | physically pulled after migration |

Result: **3-member HA etcd preserved, all 6 nodes run workloads**, zero rack penalty.

## Approach: full-downtime snapshot → restore → rejoin

Chosen over a rolling migration for mechanical simplicity. A short **full-cluster
downtime** is acceptable here (homelab). Running workloads on ipc4-9 keep serving
via kubelet during the API outage, but nothing reschedules until the API is back.

---

## Key facts (verified 2026-07-04 — re-verify before starting)

- etcd auto-snapshots: `/var/lib/rancher/k3s/server/db/snapshots/` on ipc1 (12h, keep 5).
- **Restore needs the ORIGINAL cluster's server token**: `/var/lib/rancher/k3s/server/token` on ipc1. The snapshot's CA + secrets-encryption keys are bound to it — a fresh token will NOT decrypt the restored state.
- Current endpoints hardcode ipc1: servers `server: https://192.168.88.53:6443`; agents `K3S_URL=https://192.168.88.53:6443`. **The rebuild re-points everything at the VIP `192.168.88.58` so a CP node can be lost transparently forever after.**
- **kube-vip binds `vip_interface`** — currently `enp2s0` (Pentium NIC). Elite Minis are **`eno1`**. Must change or the VIP won't bind on ipc4-6. (`manifests/kube-vip/daemonset.yaml`.)
- No PV data or workloads on ipc1-3 (tainted) → **no data migration needed**; snapshot captures all etcd state.
- IPs: ipc1 .53, ipc2 .52, ipc3 .54, ipc4 .55, ipc5 .56, ipc6 .57, ipc7 .63, ipc8 .64, ipc9 .65. VIP .58.

### Node-local storage (verified 2026-07-04 — the reinstall-safety detail)
The nodes we reinstall (ipc4-6) DO hold node-local PV data, but at paths **outside**
k3s's dirs, so `k3s-agent-uninstall.sh` (removes only `/var/lib/rancher/k3s`,
`/etc/rancher/k3s`, `/run/k3s`, `/var/lib/kubelet`, binaries) does **not** touch them:

| PVC | node | storageclass | host path |
|---|---|---|---|
| `vault/data-vault-2` | ipc4 | vault-local (Retain) | `/var/lib/vault-data` (832K) |
| `vault/data-vault-0` | ipc5 | vault-local | `/var/lib/vault-data` |
| `vault/data-vault-1` | ipc6 | vault-local | `/var/lib/vault-data` |
| `default/pelagos-build-cache` | ipc4 | local-path (Delete) | `/opt/local-path-provisioner/...` (regenerable) |
| `gruesome/gruesome-data` | ipc6 | local-path | `/opt/local-path-provisioner/...` |

So the data **survives the reinstall on disk**; the etcd restore re-creates the PV
objects (nodeAffinity pins them back to ipc4/5/6 by hostname) and they re-bind.
Everything else is NFS (`nfs-subdir-external-provisioner`, on nazgul) — node-independent.
**Still, back these dirs up right before each node's reinstall (Phase 2) as insurance**
(vault raft = 3-node, self-heals from the other two even if one member's data is lost).

---

## Phase 0 — Prep the repo (no cluster impact) — ✅ DONE, staged on branch `migrate-cp-6node`

> **STATUS:** Phase 0 config is staged on branch **`migrate-cp-6node`** (this branch),
> NOT `master`. `master` still describes the live 9-node cluster, so routine ops
> (install-pelagos.sh / upgrade-*.sh run from `master`) stay correct until migration
> day. **On migration day: `git checkout migrate-cp-6node` first**, then run the
> Phase 1+ steps so the scripts read the new roles/config. The monitoring change is
> staged on the matching `migrate-cp-6node` branch in the `home-monitoring` repo.
>
> Staged edits (this branch): `scripts/lib/node-roles.sh`, `config/k3s-server.yaml`,
> `config/k3s-server-join.yaml`, `scripts/upgrade-agents.sh`,
> `manifests/kube-vip/daemonset.yaml`. Details below (kept for reference/review).

Stage the new config so the migration just applies known-good files:

1. `scripts/lib/node-roles.sh`:
   - `CLUSTER_INIT_NODE="ipc4"`
   - `SERVER_NODES=(ipc4 ipc5 ipc6)`
   - `AGENT_NODES=(ipc7 ipc8 ipc9)`
2. `config/k3s-server.yaml` (the seed = ipc4): keep `cluster-init: true`, keep `tls-san` (.58 + hostname). **Remove the `node-taint:` block** (co-located → must schedule workloads). Keep `disable: [local-storage, servicelb]`.
3. `config/k3s-server-join.yaml` (ipc5/ipc6): set `server: "https://192.168.88.58:6443"` (VIP). Remove the `node-taint:` block. Token injected at install from ipc4.
4. Agent endpoint: agents must use `K3S_URL=https://192.168.88.58:6443` (VIP). Update wherever install writes the agent env (the K3S_URL/K3S_TOKEN env file), and any `config/k3s-agent.yaml`.
5. `manifests/kube-vip/daemonset.yaml`: `vip_interface` `enp2s0` → **`eno1`**. nodeSelector stays `node-role.kubernetes.io/control-plane: "true"` (now satisfied by ipc4-6). Keep `svc_enable=false`, `cp_enable=true`.
6. Monitoring (home-monitoring repo, `pelagos/config/prometheus/prometheus.yml`):
   - `k3s_kube_state_metrics` target `192.168.88.53:30808` → a surviving node (`192.168.88.55:30808`).
   - `k3s_nodes` static list: drop ipc1/ipc2/ipc3 (.53/.52/.54); keep .55/.56/.57/.63/.64/.65.
7. Note (don't fix yet): bastion/jump = ipc1. We already reach the cluster over the tailnet, so post-migration set the jump host to a surviving node (or drop it).

---

## Phase 1 — Pre-flight (day of, BEFORE downtime)

```bash
# 1. Fresh snapshot + copy OFF the cluster
ssh ipc1 'sudo k3s etcd-snapshot save --name premigrate'
ssh ipc1 'sudo ls -t /var/lib/rancher/k3s/server/db/snapshots/ | head -1'
# copy the newest snapshot to nazgul AND to ipc4
SNAP=<newest snapshot filename>
ssh ipc1 "sudo cat /var/lib/rancher/k3s/server/db/snapshots/$SNAP" | ssh root@nazgul "cat > /mnt/primary_storage/backups/k3s/$SNAP"
ssh ipc1 "sudo cat /var/lib/rancher/k3s/server/db/snapshots/$SNAP" | ssh ipc4 "sudo tee /root/$SNAP >/dev/null"

# 2. Grab the ORIGINAL server token (required for restore)
ssh ipc1 'sudo cat /var/lib/rancher/k3s/server/token'   # store securely; used as K3S_TOKEN on ipc4

# 3. Sanity: confirm nothing schedulable lives on ipc1-3 (should be empty)
sudo k3s kubectl get pods -A -o wide | awk '$8 ~ /ipc[123]/ && $1 !~ /kube-system|monitoring|metallb|tailscale|kube-vip|spire/'

# 4. Confirm Flux/GitOps owns the workloads (so they self-heal post-migration)
sudo k3s kubectl get kustomizations -A 2>/dev/null; sudo k3s kubectl get helmreleases -A 2>/dev/null
```

---

## Phase 2 — Migration (downtime starts)

```bash
# 1. Stop k3s everywhere (order doesn't matter now)
for n in ipc1 ipc2 ipc3; do ssh $n 'sudo systemctl stop k3s'; done
for n in ipc4 ipc5 ipc6 ipc7 ipc8 ipc9; do ssh $n 'sudo systemctl stop k3s-agent'; done

# 1b. INSURANCE: back up node-local PV data on ipc4/5/6 to nazgul before any wipe.
#     (Verified k3s-agent-uninstall.sh does NOT touch these paths, so this is belt-and-
#     suspenders — but vault is your secret store, so do it.) vault-data on all three;
#     gruesome data on ipc6. Build-cache is regenerable — skip.
for n in ipc4 ipc5 ipc6; do
  ssh $n "sudo tar -C /var/lib -czf - vault-data" | ssh root@nazgul "cat > /mnt/primary_storage/backups/k3s/vault-data-$n-premigrate.tgz"
done
ssh ipc6 "sudo tar -C /opt -czf - local-path-provisioner" | ssh root@nazgul "cat > /mnt/primary_storage/backups/k3s/localpath-ipc6-premigrate.tgz"

# 2. Wipe ipc4's old AGENT state so it can become a fresh server. k3s-agent-uninstall.sh
#    removes only /var/lib/rancher/k3s, /etc/rancher/k3s, /run/k3s, /var/lib/kubelet, binaries.
#    It does NOT touch /var/lib/vault-data or /opt/local-path-provisioner (verified) — the
#    PV data stays on disk and re-binds after the etcd restore.
ssh ipc4 'sudo systemctl stop k3s-agent; sudo /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true'

# 3. Install k3s SERVER on ipc4 with the ORIGINAL token + new server config, then restore.
#    Use ipc4's own IP for bootstrap; the VIP comes up once kube-vip is applied.
#    (install-pelagos.sh deploys config/k3s-server.yaml + the pelagos-cri unit for the role.)
./scripts/install-pelagos.sh ipc4          # role=server per updated node-roles.sh
ssh ipc4 'sudo systemctl stop k3s'
ssh ipc4 "sudo K3S_TOKEN=<original-server-token> k3s server \
    --cluster-reset \
    --cluster-reset-restore-path=/root/$SNAP"
#    ^ resets etcd to a single member (ipc4) populated from the snapshot, then exits.
ssh ipc4 'sudo systemctl start k3s'
#    Wait for ipc4 API to be Ready:
ssh ipc4 'sudo k3s kubectl get nodes'

# 4. Deploy kube-vip (eno1) so the VIP .58 comes up on ipc4, then repoint everything to it.
sudo k3s kubectl apply -f manifests/kube-vip/    # (Flux will also reconcile it)
#    Confirm .58 answers:
ssh ipc4 'ip a show eno1 | grep 192.168.88.58; curl -k https://192.168.88.58:6443/readyz'

# 5. Delete the dead Pentium node objects (etcd membership was already reset in step 3)
ssh ipc4 'sudo k3s kubectl delete node ipc1 ipc2 ipc3'

# 6. Join ipc5, ipc6 as servers (config/k3s-server-join.yaml → server: VIP .58; token from ipc4)
for n in ipc5 ipc6; do
  ssh $n 'sudo systemctl stop k3s-agent; sudo /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true'
  ./scripts/install-pelagos.sh $n          # role=server; join-token fetched from the seed
  # verify etcd grows and node is Ready before doing the next one:
  ssh ipc4 'sudo k3s kubectl get nodes; sudo k3s etcdctl member list 2>/dev/null || sudo k3s kubectl -n kube-system get pods | grep etcd'
done

# 7. Rejoin ipc7, ipc8, ipc9 as agents pointing at the VIP
for n in ipc7 ipc8 ipc9; do
  ssh $n 'sudo systemctl stop k3s-agent; sudo rm -rf /var/lib/rancher/k3s/agent/etc/k3s-agent-load-balancer.json'
  # ensure the agent env K3S_URL is the VIP, then:
  ./scripts/install-pelagos.sh $n          # role=agent
done
```

Downtime ends when ipc4-6 are Ready servers + ipc7-9 rejoined + Flux reconciled.

---

## Phase 3 — Post-migration

```bash
# Health
sudo k3s kubectl get nodes -o wide          # expect 6 Ready: ipc4-6 control-plane,etcd ; ipc7-9 <none>
sudo k3s kubectl get pods -A | grep -vE 'Running|Completed'   # empty = healthy
# etcd quorum = 3 members (ipc4-6)
# Vault still unsealed? (see so-long checklist) — restarts may re-seal; unseal per runbook.
```

Then land the plumbing changes (already staged in Phase 0):
- **home-monitoring**: deploy the updated `prometheus.yml` (git pull + `systemctl restart home-monitoring` on nazgul). Verify `k3s_nodes` = 6 targets, ksm target = a surviving node.
- **Bastion/jump**: repoint `ssh -J ipc1` usage to a surviving node, or drop it (we use the tailnet now — see `~/.ssh/config`). Update `docs/bastion.md`.
- **PXE**: retire ipc1-3 autoinstall/iPXE entries (`pxe/`), so a stray PXE boot can't try to reprovision them.
- **Docs/scripts** referencing ipc1-3: `node-roles.sh` (done in Phase 0), `backup-ipc1.sh`, `ipc1-*` runbooks, `CLAUDE.md` — update or mark historical.
- Physically **pull ipc1-3** and rack the Elite Minis.

---

## Rollback

If Phase 2 goes wrong before ipc1-3 are wiped: they still hold the original etcd.
Re-start k3s on ipc1-3 (`systemctl start k3s`), stop the half-built ipc4 server,
and you're back to the 9-node cluster. **Do NOT wipe/repurpose ipc1-3 until ipc4-6
are verified-healthy servers and you've confirmed the restore is complete.** Keep
the pre-migration snapshot on nazgul indefinitely.

## LESSONS FROM THE LIVE RUN (2026-07-04) — read before the next DR/migration

The migration succeeded but hit these — all now handled in the scripts/config, but
know them:

1. **Every reinstalled node needs a REBOOT afterward.** The churn (uninstall →
   reinstall → restore → service restarts) leaks namespace/mount state, and then
   ~all of that node's containers fail to start with
   `pelagos run failed: Failed to spawn process: Invalid argument (os error 22)`
   (a *masked* custom error — pre_exec has no `raw_os_error`, so it reads as EINVAL).
   A config reconcile does NOT clear it; a reboot does. Reboot control-plane nodes
   one at a time (quorum holds via the other two).
2. **k3s reinstall WIPES custom node labels.** `node-class` (used by vault's
   affinity, and any future perf-pinned workload) is gone after a reinstall → pods
   go `Pending` (`didn't match Pod's node affinity`). Now persisted via `node-label`
   in `config/k3s-{server,agent}.yaml` (servers=performance, agents=fastest), applied
   at registration. If you ever relabel live, also update those configs.
3. **Rejoining a node needs its stale `<node>.node-password.k3s` secret deleted**
   on the seed (else the fresh agent's password is rejected → NotReady). The
   join/agent scripts do this now.
4. **`install-pelagos.sh` only writes config + restarts** — it does NOT install the
   k3s binary or convert agent↔server. Use `restore-cluster.sh` (seed), `join-server.sh`
   (server), `install-agent.sh` (agent) — they run `get.k3s.io INSTALL_K3S_EXEC=…`.
5. **Never pipe data to `ssh "bash -s" <<HEREDOC`** — the heredoc wins stdin, the
   pipe gets SIGPIPE, nothing runs. Pass the config as a base64 ARG (the scripts do).
6. **ipc7-9 direct ssh is flaky** → `install-agent.sh` supports `JUMP=1` to hop via
   the seed (on their LAN). The old ipc1 jump-host is gone; use a surviving node.
7. **`install-pelagos.sh` placeholder** must match the config's token placeholder
   (now regex-tolerant: `<INJECTED_AT_INSTALL_FROM_[A-Z0-9]+_TOKEN>`).

## Gotchas checklist
- [ ] Used the **original server token** for the ipc4 restore (else restored secrets won't decrypt).
- [ ] kube-vip `vip_interface = eno1` (not `enp2s0`).
- [ ] Removed the `node-taint` from ipc4-6 server config (co-located workloads).
- [ ] Agents' `K3S_URL` = VIP `.58` (not ipc1).
- [ ] Deleted stale `ipc1/2/3` node objects.
- [ ] Snapshot copied OFF-cluster (nazgul) before touching anything.
- [ ] Verified no local-path PV data on ipc1-3 (none, since tainted) before wipe.
- [ ] **Rebooted each reinstalled node** + re-verified node-class labels + cleared node-password secrets.
