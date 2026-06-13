# ipc1 (control plane) → Ubuntu 26.04 upgrade runbook

ipc1 is the **single k3s server**. Its **SQLite datastore + CA certs + node token
live only on ipc1**, and all agents are pinned to `https://192.168.88.53:6443`.
So unlike a worker, ipc1 can't just be wiped and rejoined — its state must be
preserved. Do this **last**, after all workers are on 26.04 (done: ipc2–ipc6).

Facts that make it safe:
- ipc1 is **not** a tailnet subnet router — just the SSH-jump convention. Workers
  are reachable by their own tailnet names; use **ipc2 as the alternate jump**
  while ipc1 is down (it can't jump through itself).
- **nazgul is reachable** from omen directly and via the ipc1 jump → PXE control
  works during ipc1's downtime.
- **Flux** re-reconciles `manifests/` from Git → most objects are recoverable
  even without the backup; the backup covers the non-Git state (secrets, SPIRE
  registrations, PV/PVC bindings).

---

## Step 0 — ALWAYS: verified backup first (both paths need it)
```
bash scripts/backup-ipc1.sh <label>     # e.g. a timestamp
```
Briefly stops k3s, tars `/var/lib/rancher/k3s/server` + `/etc/rancher/k3s`, lands
copies on omen (`./backups/`) and nazgul (`/mnt/primary_storage/backups`), and
prints the contents + sha256. **Confirm the listing includes `server/db`,
`server/tls`, and `server/token` before proceeding.** Backup holds the CA key —
keep it locked down.

---

## Path A — PXE reinstall + restore (clean, uniform with the fleet)

**A1. Config prep (commit + deploy):**
- Convert ipc1's autoinstall (`pxe/autoinstall/a8-a1-59-43-2a-67/user-data`) network
  to **MAC-matching** `a8:a1:59:43:2a:67` (it still uses `enp2s0` by name), like the
  other Pentiums.
- Point ipc1 at 26.04: `custom.ipxe` branch + `MAC-a8a159432a67.ipxe`.
- `bash scripts/deploy-pxe-configs.sh`.

**A2. Backup** — Step 0 (run it right before the reinstall to minimise drift).

**A3. Pre-reinstall (drive by hand — ipc1 can't jump through itself):**
- Clear ipc1's MikroTik dynamic lease **via the alternate jump**:
  `ssh -J cb@ipc2.taildd208.ts.net admin@192.168.88.1 "/ip dhcp-server lease remove [find where mac-address=\"A8:A1:59:43:2A:67\" dynamic=yes]"`
- Delete ipc1's Tailscale device (API, from omen): `bash scripts/tailscale-cleanup.sh ipc1`
- Enable PXE: `bash scripts/pxe-control.sh enable ipc1`

**A4. Reinstall:** set one-shot BootNext to ipc1's IPv4 PXE entry, reboot:
```
ssh cb@ipc1.taildd208.ts.net "sudo efibootmgr --bootnext <ipc1 IPv4-PXE entry> && sudo reboot"
```
Monitor via nazgul PXE logs + `-J cb@ipc2 ... cb@192.168.88.53`. It PXE-installs
once, then boots disk (BootNext consumed). Disable PXE once it's up:
`bash scripts/pxe-control.sh disable ipc1`.

**A5. Restore:**
```
bash scripts/restore-ipc1.sh ./backups/ipc1-k3s-backup-<label>.tar.gz v1.35.5+k3s1
```
Installs Pelagos, installs the same k3s version (skip-start), drops the backed-up
datastore+certs+token back, starts k3s. Agents reconnect (same CA/token/IP).

**A6. Finish:** `bash scripts/install-nut-clients.sh ipc1`,
`bash scripts/tailscale-cleanup.sh --verify ipc1`, confirm all 6 Ready + Flux healthy.

**Downtime:** ~15–20 min control-plane only (existing pods keep running).

---

## Path B — in-place `do-release-upgrade` (no reinstall)  ← under discussion

Upgrades ipc1 24.04 → 26.04 in place; the cluster state, certs, token, IP, k3s,
Pelagos, tailscale, NUT all stay put. Far less to go wrong with the *cluster*
(nothing is wiped; agents never disconnect). Tradeoffs vs Path A:
- Departs from the fleet's clean-reinstall uniformity (carries 24.04 cruft forward).
- `do-release-upgrade` reliability (held pkgs, third-party repos — tailscale/NUT
  apt repos need re-pointing to the 26.04 series; k3s/Pelagos are binaries, not apt).
- 26.04 availability via the upgrader (LTS→LTS usually opens at the .1 point
  release; may need `-d`).

Sketch (decide details in the chat first):
1. Step 0 backup (the safety net — in-place CAN fail mid-upgrade).
2. `sudo apt update && sudo apt full-upgrade` on 24.04; reboot.
3. Re-point/disable third-party apt repos (tailscale, NUT) for 26.04.
4. `sudo do-release-upgrade` (possibly `-d` until 26.04.1); answer prompts.
5. Reboot; verify kernel 7.0, k3s + Pelagos healthy, all 6 Ready, Flux clean.
6. If it wedges → fall back to **Path A** (the backup makes this safe).

---

## Rollback
The **verified backup is the rollback** (re-restore via Path A), and **Flux**
re-reconciles GitOps-managed objects from `manifests/`. There's no spare to
rehearse on, so the safety is: verify the backup before touching ipc1, and run
the restore validation gates after.
