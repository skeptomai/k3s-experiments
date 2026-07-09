# k3s-experiments

Kubernetes learning cluster on six ipc machines: **3 control-plane+worker (HA embedded
etcd, ipc4-6) + 3 workers (ipc7-9)**. Scripts and docs for cluster management and
experiments.

History: ipc1-3 (Pentium Gold G5400T) were the original control plane until 2026-07-05
when they were retired and replaced by the faster ipc4-6 (i5-12500T). ipc4-6 were
previously workers.

## Cluster

| Node | Role | IP | SSH | MAC (primary NIC) |
|------|------|----|-----|-------------------|
| ipc4 | control-plane,etcd (seed) | 192.168.88.55 | Direct via tailnet: `ipc4.taildd208.ts.net` | `d0:ad:08:9c:d2:cb` (eno1) |
| ipc5 | control-plane,etcd | 192.168.88.56 | Jump through ipc4: `-J cb@ipc4.taildd208.ts.net cb@ipc5` | `d0:ad:08:9c:d1:45` (eno1) |
| ipc6 | control-plane,etcd | 192.168.88.57 | Jump through ipc4: `-J cb@ipc4.taildd208.ts.net cb@ipc6` | `e0:73:e7:c0:b0:08` (eno1) |
| ipc7 | worker | 192.168.88.63 | Jump through ipc4: `-J cb@ipc4.taildd208.ts.net cb@ipc7` | `e0:73:e7:3a:a6:7b` (eno1) |
| ipc8 | worker | 192.168.88.64 | Jump through ipc4: `-J cb@ipc4.taildd208.ts.net cb@ipc8` | `7c:4d:8f:aa:fa:a4` (eno1) |
| ipc9 | worker | 192.168.88.65 | Jump through ipc4: `-J cb@ipc4.taildd208.ts.net cb@ipc9` | `7c:4d:8f:aa:ef:73` (eno1) |

- Roles are the single source of truth in `scripts/lib/node-roles.sh` (servers
  ipc4-6, agents ipc7-9); scripts consult it rather than hard-coding node names.
- ipc4-6 are **intentionally untainted** — all 6 nodes run workloads. With uniform
  i5-12500/T hardware there's no reason to dedicate control-plane nodes exclusively to
  k3s overhead (unlike the old Pentium Gold control plane, which was too slow for work).
- **HA API endpoint:** kube-vip floating VIP **`192.168.88.58`**
  (`k8s-api.home.skeptomai.com`) across ipc4-6. omen kubeconfig has two contexts —
  `default` (tailnet `ipc4:6443`, reachable anywhere, not HA) and `ipc-vip` (the VIP,
  HA, LAN-only). See `docs/kube-vip.md`.
- **LoadBalancer:** MetalLB (L2/ARP), pool **`192.168.88.240-.250`**; k3s ServiceLB is
  disabled (`disable: servicelb` in the server configs). Traefik runs on `.240`. See
  `docs/metallb.md`. Both kube-vip and MetalLB are **Flux-managed** (`clusters/ipc/`), so
  a cluster rebuild brings them back automatically once Flux is bootstrapped — but the
  MikroTik DHCP/DNS reservations they depend on are **out-of-band** (see "Recreating
  from scratch" below).
- k3s v1.35.5, Ubuntu 26.04, x86_64
- ipc4-6: HP Elite Mini 800 G9, Intel Core i5-12500T (12th Gen), 6 cores / 12 threads, 32GB RAM (NVMe) — node-class: `performance`
- ipc7-9: Intel Core i5-12500 (12th Gen, non-T), 6 cores / 12 threads, 16GB RAM (NVMe ~256GB) — node-class: `fastest`
- Container runtime: Pelagos v0.65.47 on all six nodes (`pelagos://0.65.47+c748f09`)
- Pelagos configured via `/etc/rancher/k3s/config.yaml`: `container-runtime-endpoint: "unix:///run/pelagos/cri.sock"`
- Pelagos CRI service: `pelagos-cri.service` (binaries at `/usr/local/bin/pelagos` and `/usr/local/bin/pelagos-cri`)
- SSH key: `~/.ssh/id_rsa` (cb@omen)
- kubectl requires sudo on the nodes: `sudo kubectl ...`
- k3s token lives at `/var/lib/rancher/k3s/server/node-token` on ipc4

## Applying Manifests

Run `kubectl apply` from omen against the local repo (always current). Do NOT use a clone on ipc4 — it goes stale. Flux manages `manifests/` from GitHub directly; experiments are applied manually from omen via SSH.

## What Claude Can Do Directly

Unlike a typical remote-deploy workflow, Claude can SSH directly to the nodes and run kubectl/k3s commands. Scripts in `scripts/` are the preferred way to do repeatable operations.

## Rules

**Never give multiline shell commands for the user to copy/paste.** They do not copy correctly in the terminal. Every interactive command must fit on a single line. If an operation is too complex for one line, write a script, commit it, and tell the user to run it.

**Always give single-line commands** when asking the user to run something interactively.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/lib/node-roles.sh` | **Source of truth for node roles** (servers ipc4-6, agents ipc7-9); sourced by the scripts below |
| `scripts/upgrade-server.sh [channel] [node...]` | Rolling in-place upgrade of the control-plane servers (ipc4-6), one at a time to preserve etcd quorum |
| `scripts/upgrade-agents.sh [channel] [node...]` | Upgrades/joins the agent nodes (ipc7-9); refuses server nodes |
| `scripts/join-server.sh <ipc5\|ipc6>` | Joins a freshly-reinstalled control-plane node to ipc4's etcd as a server (token injected, version pinned) |
| `scripts/reinstall-nodes.sh <node> [node...]` | Full PXE reinstall of node(s): enables PXE → reboots → waits → rejoins k3s (role-dispatched: servers→join-server.sh, agents→upgrade-agents.sh) |
| `scripts/upgrade-cluster.sh [channel]` | Upgrades all nodes in correct order (servers rolling, then agents) |
| `scripts/install-pelagos.sh [node...]` | Installs/upgrades Pelagos CRI on ipc nodes (role-aware config + unit; default: all six) |
| `scripts/install-nut-clients.sh [node...]` | Installs/configures NUT client (upsmon) on ipc nodes — run after reinstall |
| `scripts/label-nodes.sh` | Applies durable `node-class` labels (performance=i5-12500T ipc4-6, fastest=i5-12500 non-T ipc7-9) for capability-based scheduling; idempotent, run after reinstall |
| `scripts/deploy-pxe-configs.sh` | Deploys PXE iPXE scripts + autoinstall configs to nazgul (run from omen) |
| `scripts/pxe-control.sh <status\|enable\|disable> [node]` | Enables/disables PXE boot per node (run from omen) |
| `scripts/tailscale-cleanup.sh [--verify] <node...>` | Deletes stale Tailscale device(s) for a node before reinstall so it reclaims its name; `--verify` checks post-install. Needs a Tailscale OAuth client (devices:core write) via `TS_OAUTH_CLIENT_ID`/`_SECRET` env or 1Password `op://Private/Tailscale OAuth k3s`. Called automatically by `reinstall-nodes.sh`; no-op with a WARN if creds absent. |
| `scripts/provision-tpm-devid.sh <node>` | Generates a TPM-bound DevID key on the node, creates a CSR, signs it with the DevID CA (key retrieved from 1Password `ipc-cluster DevID CA key`), and installs cert+blobs at `/etc/spire/`. Called automatically by `reinstall-nodes.sh`; warns if 1Password not authenticated. Idempotent. |
| `scripts/shutdown-cluster.sh` | Gracefully cordons all nodes, drains workers then control plane, shuts down workers first and ipc4 last |

## PXE Reinstall Workflow

**Automated:** `bash scripts/reinstall-nodes.sh ipc5` (or any of ipc5-ipc9) — handles
the full cycle end-to-end and **role-dispatches the rejoin**: control-plane nodes
(ipc5/ipc6) rejoin as servers via `join-server.sh`; workers (ipc7-9) via
`upgrade-agents.sh`. Claude can run this directly. **ipc4 (the etcd seed) is never
reinstalled by this script** — it requires the manual backup/restore runbook.
Reinstalling a *server* node (ipc5/ipc6) is safe (etcd is replicated); k3s removes its
old etcd member on `kubectl delete node` and it re-joins fresh — verify membership after
with `kubectl get nodes -l node-role.kubernetes.io/etcd`.

**Manual steps** (only needed for ipc4 or if the automated script fails):

1. `bash scripts/deploy-pxe-configs.sh` — sync repo configs to nazgul
2. `bash scripts/pxe-control.sh enable <node>` — enable PXE for the node
3. Reboot the node
4. Wait for autoinstall (~10 min), then `bash scripts/pxe-control.sh disable <node>`
5. Check DHCP address (see MikroTik note below if wrong)
6. Clear stale SSH known_hosts on omen
7. Remove stale Tailscale device; rename new one if it registered as `<node>-1`
8. Rejoin k3s + install Pelagos — **server (ipc5/ipc6):** `bash scripts/join-server.sh <node>`; **worker (ipc7-9):** `bash scripts/upgrade-agents.sh <node>`
9. `bash scripts/provision-tpm-devid.sh <node>` — provision TPM DevID cert (requires `op` authenticated)
10. `bash scripts/install-nut-clients.sh <node>` — restore NUT UPS monitoring
11. `bash scripts/label-nodes.sh` — restore the node's `node-class` label (labels don't survive a fresh registration)

**After ipc4 reinstall** (wipes etcd — full cluster rebuild):
- Install k3s, Pelagos, rejoin agents, bootstrap Flux (GitHub token in 1Password)
- Scripts use tailnet hostnames — if Tailscale not yet up, use 192.168.88.55 directly

## Recreating from scratch (what's automated vs out-of-band)

A full rebuild restores most of the cluster from Git; a few pieces live on the MikroTik
and must be re-applied by hand.

**Automated (comes back on rebuild):**
- **k3s server/agent config** — `config/k3s-server.yaml` (ipc4, cluster-init + tls-san +
  `disable: servicelb`), `config/k3s-server-join.yaml` (ipc5/6), `config/k3s-agent.yaml`.
  Deployed by `install-pelagos.sh` (role-aware). The HA control plane comes from
  `cluster-init` on ipc4 + `join-server.sh` for ipc5/6.
- **kube-vip + MetalLB** — Flux reconciles `clusters/ipc/{kube-vip,metallb,metallb-config}.yaml`
  → `manifests/{kube-vip,metallb,metallb-config}/` once Flux is bootstrapped. No manual apply.
- **node-class labels** — `scripts/label-nodes.sh`.

**Out-of-band on the MikroTik (NOT in Git — re-apply by hand; see orgfiles `home-network/dns-dhcp.md`):**
- **Static leases** for all six nodes (by MAC → IP).
- **DHCP pool** must exclude the reserved IPs:
  `ranges=192.168.88.10-192.168.88.57,192.168.88.59-192.168.88.239`
  (excludes `.58` = kube-vip VIP, and `.240-.254` = MetalLB pool).
- **Static DNS:** `k8s-api.home.skeptomai.com → 192.168.88.58`.
- These are prerequisites: kube-vip's VIP `.58` and MetalLB's `.240-.250` must not be in
  the DHCP pool, or they'll collide with dynamic leases.

**Reserved IP map (bridge-lan 192.168.88.0/24):**
| IP(s) | Purpose | Reserved how |
|-------|---------|--------------|
| `.55-.57` | ipc4-6 (control-plane) | MikroTik static leases (by MAC) |
| `.58` | kube-vip control-plane VIP | DHCP pool split (excluded) |
| `.63-.65` | ipc7-9 (workers) | MikroTik static leases (by MAC) |
| `.240-.250` | MetalLB LoadBalancer pool | DHCP pool shrunk to `.239` |

## MikroTik DHCP Lease Reset

The autoinstall configs use `dhcp-identifier: mac` in netplan so the DHCP client identifies by MAC address. Static leases should bind correctly without manual intervention.

**Before reinstalling**, always ensure there are no dynamic leases for the node's MAC — MikroTik may create dynamic leases during PXE DHCP that conflict with the static lease, causing the node to get a wrong IP. `reinstall-nodes.sh` does this automatically, but when doing a manual reinstall run this first via MikroTik SSH:

```
/ip dhcp-server lease remove [find where mac-address="AA:BB:CC:DD:EE:FF" dynamic=yes]
```

**If a node gets the wrong IP after reinstall**, the static lease may need resetting:

```
/ip dhcp-server lease remove [find where address=192.168.88.XX]
/ip dhcp-server lease add address=192.168.88.XX mac-address=AA:BB:CC:DD:EE:FF server=defconf
```

Then reboot the node. IPs: ipc4=192.168.88.55, ipc5=192.168.88.56, ipc6=192.168.88.57, ipc7=192.168.88.63, ipc8=192.168.88.64, ipc9=192.168.88.65

## EFI Boot Order

All nodes are configured PXE-first (set via `efibootmgr`, persists in NVRAM). Normal boots are safe — PXE falls through to disk when nazgul returns no boot response. Accidental reinstall is prevented nazgul-side by `pxe-control.sh`.

| Node | Boot order |
|------|-----------|
| ipc4 | 0003 PXE IP4 Intel I219-LM (d0:ad:08:9c:d2:cb), 0006 Ubuntu, ... |
| ipc5 | 0003 PXE IP4 Intel I219-LM (d0:ad:08:9c:d1:45), 0001 Ubuntu, ... |
| ipc6 | verify with `sudo efibootmgr` — PXE IP4 (e0:73:e7:c0:b0:08) should be first |
| ipc7 | verify with `sudo efibootmgr` — PXE IP4 (e0:73:e7:3a:a6:7b) should be first |
| ipc8 | verify with `sudo efibootmgr` — PXE IP4 (7c:4d:8f:aa:fa:a4) should be first |
| ipc9 | verify with `sudo efibootmgr` — PXE IP4 (7c:4d:8f:aa:ef:73) should be first |

To query: `sudo efibootmgr` on any node. To fix if a reinstall resets it: `sudo efibootmgr --bootorder <pxe-entry>,0002,...`

All HP Elite Mini 800 G9 nodes require "Network Boot" enabled in BIOS firmware settings (F2 at POST → Advanced → Network Boot or similar). This is a one-time physical setup — efibootmgr boot order alone is not sufficient.

## Node Role Notes (k3s install)

The k3s install script does not persist role information, so role must be supplied
correctly every time. The role map lives in `scripts/lib/node-roles.sh`; the scripts
consult it. Two symmetric gotchas:

- **Agents (ipc7-9):** `K3S_URL` and `K3S_TOKEN` must be passed explicitly, or the
  installer wrongly comes up as a server. See `scripts/upgrade-agents.sh`.
- **Servers (ipc5/ipc6):** must be installed with `INSTALL_K3S_EXEC=server` **and** a
  `config.yaml` that already contains `server:` + `token:` (the SERVER token from
  `/var/lib/rancher/k3s/server/token`, not the agent `node-token`) — otherwise the
  installer cluster-inits a *new* etcd instead of joining ipc4's. The version is
  pinned to the seed's running version to avoid etcd skew. See
  `scripts/join-server.sh`. `install-pelagos.sh` deploys the matching role config
  (and injects the token for joining servers) automatically.
