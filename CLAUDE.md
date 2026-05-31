# k3s-experiments

Kubernetes learning cluster on three ipc machines. Scripts and docs for cluster management and experiments.

## Cluster

| Node | Role | IP | SSH | MAC (enp2s0) |
|------|------|----|-----|--------------|
| ipc1 | control-plane | 192.168.88.53 | Direct via tailnet: `ipc1.taildd208.ts.net` | `a8:a1:59:43:2a:67` (enp2s0) |
| ipc2 | worker | 192.168.88.52 | Jump through ipc1: `-J cb@ipc1.taildd208.ts.net cb@ipc2` | `a8:a1:59:43:2a:ed` (enp2s0) |
| ipc3 | worker | 192.168.88.54 | Jump through ipc1: `-J cb@ipc1.taildd208.ts.net cb@ipc3` | `a8:a1:59:43:2a:74` (enp2s0) |

- k3s v1.32.x, Ubuntu 24.04, x86_64, 4 cores, 30GB RAM per node
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

## Agent Upgrade Notes

When upgrading agent nodes, `K3S_URL` and `K3S_TOKEN` **must always be passed explicitly**. The install script does not persist role information — without these vars it will incorrectly install the node as a server. See `scripts/upgrade-agents.sh` for the correct pattern.
