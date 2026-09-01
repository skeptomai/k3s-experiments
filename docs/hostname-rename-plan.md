# Cluster Hostname Rename — Analysis & Plan (deferred)

**Status**: Analyzed 2026-08-23, not pursued. Current names (ipc4-9) are staying.
Keeping this doc in case the question comes up again later.

## Why this isn't a simple rename

The OS hostname is the k3s node identity *and* the etcd member identity. Renaming
a live node doesn't rename its k8s object — it retires one node and admits a new
one under a new name. Three layers must agree or things break in confusing ways:

1. **OS hostname** — set once, at install time, by
   `pxe/autoinstall/<mac>/{meta-data,user-data}` → `hostname: ipcN`. Live nodes
   don't re-read this; only a reinstall applies it.
2. **k3s node object name** (`kubectl get nodes`) — derived from the OS hostname
   at kubelet registration. No `node-name:` override is currently set in
   `config/k3s-server*.yaml` / `config/k3s-agent.yaml`.
3. **etcd member name** (control-plane only) — `ipc4-82e6f022` style, hostname +
   random suffix, assigned at `cluster-init`/join time. Confirmed via
   `kubectl get nodes -l node-role.kubernetes.io/etcd`.

Renaming any of ipc4-9 means that node leaves the cluster (and etcd, if
control-plane) under its old name and rejoins under a new one — exactly what
`scripts/reinstall-nodes.sh` already does today for node recovery. A rename
should reuse that path rather than attempt a live in-place hostname change.

**Assumption**: IPs and MACs stay pinned; only hostnames change. Re-addressing
the network too would be a materially bigger job (kube-vip/MetalLB pool math).

## Inventory of what references ipc4-9

### Layer 1 — the mechanism (must change first, before any node is touched)
- `pxe/autoinstall/<mac>/{meta-data,user-data}` — literal `hostname: ipcN` /
  `instance-id: ipcN`, keyed by MAC (MAC doesn't change, so directory names stay;
  only file contents change)
- `pxe/MAC-*.ipxe` — boot banner text per node
- `scripts/lib/node-roles.sh`, `scripts/lib/node-maps.sh` — the two files
  designed as sources of truth (`SERVER_NODES`, `AGENT_NODES`, name→IP, name→MAC)
- `docs/mikrotik/dhcp-leases.rsc` (comment field only, IP/MAC binding unchanged),
  `docs/mikrotik/dns-static.rsc` (A records for ipc7-9 — ipc4-6 apparently have
  no static DNS entries currently; confirm on the router directly)

### Layer 2 — duplicates of layer 1 that were never refactored onto the shared libs
Each of these is an independent point of failure:
- Standalone `NODE_IP`/`ROLE` associative arrays in `install-kubevirt-node-prereqs.sh`,
  `install-node-monitoring.sh`, `install-nut-clients.sh`,
  `install-pelagos-local-build.sh`, `install-pelagos.sh`, `upgrade-agents.sh`,
  `upgrade-server.sh`, `cluster-scheduler/shutdown-cluster.sh`
- ~~`dotfiles/scripts/check-temps.sh` — a **third, cross-repo** copy of the same mapping~~
  resolved 2026-08-31: trimmed to `check-nazgul-temps.sh`, nazgul only, no ipc4-9
  IP mapping left in it (that half moved to `cluster-health.sh`'s Prometheus queries)
- `scripts/cluster-kasa-outlet.py` + its duplicate under `cluster-scheduler/` —
  name→Kasa-outlet-label dict
- Hardcoded `-J cb@ipc4.taildd208.ts.net` bastion strings in ~20 scripts (ipc4
  specifically, as the SSH jump host — every other node's reachability depends
  on this staying consistent)

### Layer 3 — live Kubernetes objects that pin by hostname
- `manifests/openbao/storage.yaml` — three PVs literally *named*
  `openbao-data-ipc4/5/6` with `nodeAffinity In:[ipc4]` etc. This is the one
  place a rename risks **data**, not just config — PV names aren't renamable in
  place, so this needs either a migration plan or accepting the PV keeps its old
  name forever while its affinity value changes.
- `nodeSelector: {kubernetes.io/hostname: ipcN}` in
  `manifests/spire/server-statefulset.yaml` and several experiment manifests
- `~/.kube/config` on every machine (omen, this laptop, any other) —
  `server: https://ipc4.taildd208.ts.net:6443` under the `default` context

### Layer 4 — observability that goes silently wrong (no error, just blank data)
- `docs/node-temperatures-grafana-dashboard.json`,
  `docs/platform-overhead-dashboard.json` — hardcoded `node="ipc4"` PromQL
  matches per panel. Prometheus scrape configs relabel by IP
  (`{node: ipc4}` static label) too, so they'd need updating; old timeseries
  under the old label become an orphaned gap in history rather than continuing.

### Layer 5 — documentation
~40+ files (`CLAUDE.md`, `docs/cluster-architecture.md`, `docs/vip-architecture.md`,
Mermaid diagrams with node IDs literally named `ipc4box`..`ipc9box`, postmortems,
runbooks). Lower operational risk. `docs/ipc4-pod-pileup-postmortem.md`'s
*filename* is cross-referenced from 9 other files (Flux manifest comments) —
recommend leaving incident postmortem filenames alone as a historical record
rather than renaming and re-linking.

## Recommended sequencing (if ever pursued)

1. **Decide the new naming scheme first** and update `CLAUDE.md`'s node table +
   `scripts/lib/node-roles.sh` / `node-maps.sh` — these become the spec the rest
   of the work is checked against.
2. **Update the PXE layer** (`pxe/autoinstall/*/user-data`, `pxe/*.ipxe`,
   MikroTik DNS comments) and run `deploy-pxe-configs.sh` — must land *before*
   any node is reinstalled, or the reinstall reapplies the old name.
3. **Update Layer 2 duplicates and Layer 3 manifests in the same commit** —
   especially `openbao/storage.yaml`, since a partially-updated affinity value
   would strand the PV.
4. **Roll workers first** (ipc7-9, any order, no quorum risk) via
   `reinstall-nodes.sh <old-name>` — each exits under the old name and rejoins
   under the new one, same mechanics as any other reinstall.
5. **Roll control-plane one at a time** (ipc5, ipc6, then ipc4 last — it's the
   etcd seed and the universal SSH bastion; every other node's reachability
   depends on it staying up until last). Verify etcd membership after each
   (`kubectl get nodes -l node-role.kubernetes.io/etcd`) before touching the next.
6. **Update `~/.kube/config`** on every machine that talks to the cluster — or
   better, switch everything to the `ipc-vip` context pointed at `192.168.88.58`,
   which doesn't care about individual node names and sidesteps this whole
   category of breakage going forward.
7. **Update Grafana dashboards and re-verify Prometheus is scraping under new labels.**
8. **Sweep remaining docs last** — no functional risk, just accuracy.

## Open questions if this is revisited

- **Does ipc4's special role (SSH bastion, PXE seed, etcd seed) move to a
  differently-named node, or does the "first of the six" stay the bastion
  regardless of name?** ~20 scripts hardcode ipc4-as-bastion specifically.
- **Fix pre-existing bugs found during the sweep while in there, or strictly
  rename-only?**
  - `experiments/28-spire-tpmdevid-patch/run-all-trials.sh` has a variable
    named `IPC9` assigned ipc4's address.
  - `docs/add-worker-nodes.md` has stale IPs (.60-.62) that don't match the
    current .63-.65.
