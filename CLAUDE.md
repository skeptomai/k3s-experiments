# k3s-experiments

Kubernetes learning cluster on three ipc machines. Scripts and docs for cluster management and experiments.

## Cluster

| Node | Role | IP | SSH | MAC (enp2s0) |
|------|------|----|-----|--------------|
| ipc1 | control-plane | 192.168.88.53 | Direct via tailnet: `ipc1.taildd208.ts.net` | `a8:a1:59:43:2a:67` (enp2s0) |
| ipc2 | worker | 192.168.88.52 | Jump through ipc1: `-J cb@ipc1.taildd208.ts.net cb@ipc2` | `a8:a1:59:43:2a:ed` (enp2s0) |
| ipc3 | worker | 192.168.88.54 | Jump through ipc1: `-J cb@ipc1.taildd208.ts.net cb@ipc3` | `a8:a1:59:43:2a:74` (enp2s0) |

- k3s v1.35.5, Ubuntu 24.04, x86_64, 4 cores, 30GB RAM per node
- Container runtime: Pelagos v0.65.5 on all three nodes (`pelagos://0.1.0`)
- Pelagos configured via `/etc/rancher/k3s/config.yaml`: `container-runtime-endpoint: "unix:///run/pelagos/cri.sock"`
- Pelagos CRI service: `pelagos-cri.service` (binaries at `/usr/local/bin/pelagos` and `/usr/local/bin/pelagos-cri`)
- SSH key: `~/.ssh/id_rsa` (cb@omen)
- kubectl requires sudo on the nodes: `sudo kubectl ...`
- k3s token lives at `/var/lib/rancher/k3s/server/node-token` on ipc1

## Repo Locations on Nodes

- ipc1: `~/Projects/k3s-experiments` (cloned 2026-05-24)
- ipc2/ipc3: not cloned — apply via ipc1

## What Claude Can Do Directly

Unlike a typical remote-deploy workflow, Claude can SSH directly to the nodes and run kubectl/k3s commands. Scripts in `scripts/` are the preferred way to do repeatable operations.

## Rules

**Never give multiline shell commands for the user to copy/paste.** They do not copy correctly in the terminal. Every interactive command must fit on a single line. If an operation is too complex for one line, write a script, commit it, and tell the user to run it.

**Always give single-line commands** when asking the user to run something interactively.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/upgrade-server.sh [channel]` | Upgrades ipc1 control plane |
| `scripts/upgrade-agents.sh [channel]` | Upgrades ipc2/ipc3 workers (fetches token automatically) |
| `scripts/upgrade-cluster.sh [channel]` | Upgrades all nodes in correct order |
| `scripts/install-pelagos.sh [node...]` | Installs/upgrades Pelagos CRI on ipc nodes (default: all three) |
| `scripts/deploy-pxe-configs.sh` | Deploys PXE iPXE scripts + autoinstall configs to nazgul (run from omen) |
| `scripts/pxe-control.sh <status\|enable\|disable> [node]` | Enables/disables PXE boot per node (run from omen) |

## PXE Reinstall Workflow

All PXE scripts run from omen directly — no manual SSH to nazgul required.

1. `bash scripts/deploy-pxe-configs.sh` — sync repo configs to nazgul (deploys iPXE files as **disabled**)
2. `bash scripts/pxe-control.sh enable <node>` — enable PXE for the node to reinstall
3. Reboot the node into PXE
4. `bash scripts/pxe-control.sh disable <node>` — disable PXE after install completes
5. Clear MikroTik static DHCP lease (stale client-id after reinstall — see below)
6. Clear stale SSH known_hosts on omen
7. Remove stale Tailscale device; rename new one if it registered as `<node>-1`

**After ipc1 reinstall** (wipes etcd — full cluster rebuild):
- Install k3s, Pelagos, rejoin agents, bootstrap Flux (GitHub token in 1Password)
- Scripts use tailnet hostnames — if Tailscale not yet up, use 192.168.88.53 directly

## MikroTik DHCP Lease Reset (required after every reinstall)

Ubuntu's new machine-id after reinstall doesn't match the cached client-id in the MikroTik static lease, so the node camps on a dynamic address. Fix via MikroTik SSH:

```
/ip dhcp-server lease remove [find where address=192.168.88.XX]
/ip dhcp-server lease add address=192.168.88.XX mac-address=AA:BB:CC:DD:EE:FF server=defconf
```

Then reboot the node. IPs: ipc1=192.168.88.53, ipc2=192.168.88.52, ipc3=192.168.88.54

## Agent Upgrade Notes

When upgrading agent nodes, `K3S_URL` and `K3S_TOKEN` **must always be passed explicitly**. The install script does not persist role information — without these vars it will incorrectly install the node as a server. See `scripts/upgrade-agents.sh` for the correct pattern.
