# Runbook: Add Worker Nodes (ipc7–ipc9)

Add three new **worker** (agent) nodes to the cluster. The control plane stays at 3
(ipc1-3); these join as `performance`-class workers. Most of the work is automated —
the role-aware install (`scripts/lib/node-roles.sh`) and GitOps (Flux) extend to new
workers with no changes to kube-vip / MetalLB.

## Decisions (locked)

| Node | Role | IP (static lease) | `node-class` | Hardware |
|------|------|-------------------|--------------|----------|
| ipc7 | worker (agent) | 192.168.88.60 | fastest | HP Elite Mini 800 G9, i5-12500 (non-T, 65W) |
| ipc8 | worker (agent) | 192.168.88.61 | fastest | " |
| ipc9 | worker (agent) | 192.168.88.62 | fastest | " |

`.60-.62` verified free (2026-06-30). Static MikroTik leases by MAC, same as ipc1-6
(they live inside the DHCP pool but are reserved — no pool change needed). Primary NIC
is `eno1` (like ipc4-6).

## Storage decision (do at unboxing)

The HP Elite Mini 800 G9 has **two M.2 NVMe slots** + an optional 2.5″ SATA bay
(bracket HP P/N 13L70AA). ipc4-6 currently use **one** 256 GB NVMe, whole-disk OS, no
data partition.

**Recommended:** drop a **2nd M.2 NVMe** (e.g. 1 TB) into each new node as a dedicated
**data disk** for a CSI (Longhorn/OpenEBS) — this is what the Kamaji tenant-etcd work
(#6) wants: replicated block storage that isn't sharing I/O with the OS disk.
- The autoinstall **must install the OS on the boot NVMe only** and leave the 2nd disk
  untouched (the per-MAC `user-data` `storage:` section targets the boot device).
- Retrofit ipc4-6 with a 2nd M.2 later (their spare slot is free).

## Phase 1 — Repo prep (do NOW, before racking; only the MAC waits for the hardware)

1. **Collect each node's `eno1` MAC** (read from the BIOS network screen or the first
   DHCP request). This is the only item that needs the physical node.
2. **PXE autoinstall per-MAC** — copy an existing i5 node's config and edit:
   ```bash
   # template = ipc4 (d0-ad-08-9c-d2-cb)
   cp -r pxe/autoinstall/d0-ad-08-9c-d2-cb pxe/autoinstall/<new-mac-dashed>
   # edit pxe/autoinstall/<new-mac-dashed>/user-data:
   #   - identity.hostname: ipc7
   #   - network match macaddress + the late-commands netplan macaddress
   #   - confirm storage targets the BOOT disk only (don't wipe the 2nd NVMe)
   ```
3. **iPXE MAC file** — `cp pxe/MAC-d0ad089cd2cb.ipxe pxe/MAC-<newmac>.ipxe` (point at the
   24.04→26.04 install branch like the other i5s).
4. **Role map** — add `ipc7 ipc8 ipc9` to `AGENT_NODES` in `scripts/lib/node-roles.sh`.
5. **Script node maps** — add IP/NIC/MAC entries to `scripts/reinstall-nodes.sh`
   (`NODE_IP`, `NODE_NIC=eno1`, `NODE_MAC`) and `scripts/install-pelagos.sh`
   (`NODE_IP`, `DEFAULT_NODES`).
6. **Labels** — `scripts/label-nodes.sh` labels ipc4-6 `node-class: performance`
   and ipc7-9 `node-class: fastest` (i5-12500 non-T, 65W — the fastest tier);
   confirm it covers the new nodes (extend its node list if it enumerates explicitly).
7. **Deploy PXE configs** — `bash scripts/deploy-pxe-configs.sh` (push to nazgul).

## Phase 2 — MikroTik (out-of-band; see orgfiles `home-network/dns-dhcp.md`)

```
# static DHCP leases (reserve the IPs by MAC) — run via the ipc1 jump
/ip dhcp-server lease add address=192.168.88.60 mac-address=<ipc7-mac> server=defconf comment=ipc7
/ip dhcp-server lease add address=192.168.88.61 mac-address=<ipc8-mac> server=defconf comment=ipc8
/ip dhcp-server lease add address=192.168.88.62 mac-address=<ipc9-mac> server=defconf comment=ipc9
# DNS
/ip dns static add name=ipc7.home.skeptomai.com address=192.168.88.60 ttl=1d
/ip dns static add name=ipc8.home.skeptomai.com address=192.168.88.61 ttl=1d
/ip dns static add name=ipc9.home.skeptomai.com address=192.168.88.62 ttl=1d
```

## Phase 3 — Physical install

1. (Optional but recommended) install the **2nd M.2 NVMe** data disk.
2. Rack + cable ethernet (the G9 has a single onboard RJ45 → `eno1`).
3. **BIOS:** enable **Network Boot** (F10 at POST → Advanced → Boot / Network Boot).
   Required for PXE on these — the same one-time step ipc4/ipc5 needed.
4. Confirm/record the `eno1` MAC.

## Phase 4 — Provision (live, once racked + configs deployed)

```bash
bash scripts/reinstall-nodes.sh ipc7 ipc8 ipc9
```
This drives the full cycle per node: enable PXE → reboot → autoinstall (~30 min on
26.04) → disable PXE → clear known_hosts → **role-dispatched rejoin** (workers →
`upgrade-agents.sh` → join as agents + install Pelagos CRI) → NUT (`install-nut-clients.sh`)
→ verify. Then:
```bash
bash scripts/label-nodes.sh            # ipc4-6 performance, ipc7-9 fastest
```

## Phase 5 — Verify

```bash
kubectl get nodes -o wide                                  # 9 Ready; ipc7-9 = <none> (worker)
kubectl get nodes -L node-class | grep ipc[789]            # fastest
for n in ipc7 ipc8 ipc9; do ssh $n 'pelagos --version; upsc cyberpower@192.168.89.2 ups.status'; done
kubectl -n metallb-system get pods -o wide | grep ipc[789] # MetalLB speaker auto-scheduled
```

## Auto-covered — NO action needed

- **MetalLB speaker** (DaemonSet) schedules onto the new workers automatically.
- **kube-vip** is control-plane-only — unaffected.
- **NUT upsmon** — `reinstall-nodes.sh` runs `install-nut-clients.sh` per node.
- **Flux / GitOps** — unchanged; new workers just add capacity.
- **DHCP pool / VIP / MetalLB pool** — unchanged (static leases are reservations within
  the existing pool; no range edit needed).

## Notes

- This adds **3 performance workers** (→ 6 total) with no control-plane change. etcd
  stays 3-node (the right size; don't promote workers to servers).
- If you add the 2nd NVMe to all six workers, that unblocks a proper CSI for Kamaji
  (#6) — replicated NVMe storage isolated from the OS disk.

## Cluster deploy key (uniform in-cluster build/roll hub)

The in-cluster build/roll (build Job → stage on a fast node → fan out to all nodes,
install + `systemctl restart pelagos-cri`) needs the build node to SSH to every other
node. Rather than depend on ad-hoc per-node keys, a dedicated **`cluster-deploy`**
keypair provides node-agnostic, PXE-durable trust:

- **Public key:** `pxe/keys/cluster-deploy.pub`, provisioned into **every** node's
  autoinstall `ssh.authorized-keys` — so a freshly PXE-installed node trusts it with
  no manual step. Keep every `pxe/autoinstall/*/user-data` carrying this line.
- **Private key:** on the floating build nodes **ipc4/5/6** at `~/.ssh/cluster-deploy`
  (0600) with an `~/.ssh/config` block using it for `ipc*`/`192.168.88.*`. Durable
  copy: `nazgul:/mnt/primary_storage/cluster-deploy-key/` (0600 root).
- **`reinstall-nodes.sh`** clears a re-imaged node's stale host key from the build-hub
  nodes' `known_hosts` (its new host key would otherwise trip a mismatch on delivery).

**After reinstalling a *build* node (ipc4/5/6)** the private key + ssh config are NOT in
user-data (secret), so re-place them from nazgul:

```bash
scp root@nazgul:/mnt/primary_storage/cluster-deploy-key/cluster-deploy ~/.ssh/cluster-deploy
chmod 600 ~/.ssh/cluster-deploy
# add the Host ipc* block with IdentityFile ~/.ssh/cluster-deploy (see other build nodes)
```

Reinstalling a **worker** (ipc1-3, 7-9) needs nothing extra — it trusts the deploy key
straight from user-data.
