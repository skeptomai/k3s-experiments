# Cluster Night Mode

Automated nightly shutdown (21:00) and startup (05:00) to save power.

## How it works

**Runs via root crontab on nazgul (always-on NAS), not omen.** The original
design (2026-07-18) used a systemd timer on omen, but omen is a laptop that
travels and sleeps — automation tied to it wasn't reliable. It was migrated
to nazgul-hosted cron jobs the same day; the omen timer units were left in
place, disabled, for weeks afterward and caused real confusion (see
"History" below) before being deleted 2026-08-19. **If you're looking for
this automation, it is on nazgul, not omen.**

Each cron line runs a one-shot Pelagos container built from
`scripts/cluster-scheduler/`:

```
0 21 * * * pelagos run --rm --network=bridge \
    --bind-ro /root/.ssh/id_rsa:/root/.ssh/id_rsa \
    --bind-ro /etc/cluster-scheduler/kubeconfig:/etc/cluster-scheduler/kubeconfig \
    --env-file /etc/cluster-scheduler/pushover.env \
    localhost:5004/cluster-scheduler:latest /scripts/night-off.sh \
    >> /var/log/cluster-scheduler.log 2>&1

0 5 * * * ... /scripts/morning-on.sh >> /var/log/cluster-scheduler.log 2>&1
```

(`crontab -l` on nazgul as root is the live source of truth for the exact
schedule — the block above is a snapshot.)

**21:00 — `night-off.sh`**

1. `silence-alerts.sh night 05:30` — creates an Alertmanager silence matching
   every alertname (`alertname =~ ".+"`), expiring 05:30
2. `shutdown-cluster.sh` — drains workers, then secondary control-plane
   (ipc5/6), then the seed (ipc4); sends `shutdown -h now` to each node in
   the same order (workers → ipc5/6 → ipc4 last)
3. Waits 60s for nodes to fully power off
4. `cluster-kasa-outlet.py off all` — cuts power to all six outlet slots on
   the Kasa HS300 (`192.168.88.31`)

**05:00 — `morning-on.sh`**

1. `cluster-kasa-outlet.py on all` — restores power to all six nodes
2. Waits for the API server to become reachable (up to 10 min)
3. Waits for all 6 nodes to report `Ready` (up to 10 min)
4. Uncordons all nodes
5. **Recycles SPIRE agent pods** (`kubectl delete pods -n spire -l
   app=spire-agent`) — SPIRE's CA rotates every ~12h; the agent's init
   container only fetches a fresh trust bundle once per pod creation, so a
   pod that survived from before an overnight power-off carries a stale
   bundle and fails TLS handshake on reconnect. Deleting the pods forces a
   fresh bootstrap (cheap, <30s). If fewer than 6/6 SPIRE agents come back
   Ready within 45s, fires a **direct Pushover alert** (see below) —
   this is the most common source of a SPIRE-related push notification.

**05:30 — Silence auto-expires** in Alertmanager. The 30-minute grace window
covers normal boot time (~10-15 minutes). If the cluster isn't healthy by
05:30, alerts fire for real — you get paged. Every failure mode produces
noise rather than silence.

## Direct Pushover alerts bypass the Alertmanager silence — by design

`night-off.sh` and `morning-on.sh` both call `pushover-alert.sh` directly on
specific failure conditions, **independent of Alertmanager and its silence**:

- `night-off.sh`: alert-silence step failed; `shutdown-cluster.sh` failed
  (script exits 1, Kasa power is deliberately **not** cut in this case —
  yanking power on nodes that never got a clean `shutdown -h now` risks
  filesystem corruption); Kasa power-off failed
- `morning-on.sh`: any unhandled failure (`ERR` trap, `set -e`) at any point
  in the script; fewer than 6/6 SPIRE agents Ready after recycling

This is intentional (see `pushover-alert.sh`'s own header comment): a
2026-08-15 incident where `silence-alerts.sh` failed, the failure was
silently swallowed by a bash subshell/`set -e` gotcha, and the whole
night-off run aborted with **no notification at all** — the fleet stayed up
all night with nobody told anything was wrong. These direct pushovers are
the fix: they fire specifically when the automation itself is broken, and
they cannot be silenced by the same Alertmanager silence that (correctly)
suppresses the expected noise of nodes going up/down during a normal cycle.

**Practical implication:** if you get a SPIRE (or any) Pushover alert during
the 21:00-05:30 window, it means one of the two specific conditions above
actually happened — it is not spillover from the expected shutdown/startup
noise, since that noise is what the Alertmanager silence exists to suppress.
Check `/var/log/cluster-scheduler.log` on nazgul for that night's/morning's
run to see exactly what failed.

## Timing

| Time  | Event |
|-------|-------|
| 21:00 | Silence created (expires 05:30), graceful drain starts |
| 21:05-21:10 | All nodes OS-shutdown, Kasa power cut |
| 05:00 | Kasa power restored, nodes boot |
| 05:02-05:05 | k3s up, nodes Ready, SPIRE agents recycled |
| 05:05-05:15 | Pods scheduled and Running |
| 05:30 | Silence expires — alerts live again |

## Manual override

```bash
# Power on now (cluster is off)
scripts/cluster-morning-on.sh

# Power off now (skips graceful drain — use shutdown-cluster.sh for graceful)
uv run scripts/cluster-kasa-outlet.py off all

# Silence alerts manually for 4h (e.g. during maintenance)
scripts/silence-alerts.sh on 4h

# Check silence state
scripts/silence-alerts.sh status

# Disable nightly automation temporarily (on nazgul, as root)
ssh root@nazgul.taildd208.ts.net "crontab -l > /etc/cluster-scheduler/crontab.default; crontab -r"

# Re-enable
ssh root@nazgul.taildd208.ts.net "crontab /etc/cluster-scheduler/crontab.default"
```

`scripts/cluster-night-off.sh` / `scripts/cluster-morning-on.sh` (top-level,
not in `cluster-scheduler/`) remain as manual convenience wrappers runnable
from omen — they call the same underlying `silence-alerts.sh` /
`shutdown-cluster.sh` / `cluster-kasa-outlet.py` pieces directly over SSH
rather than through the nazgul container. They are **not** what runs
automatically; nazgul's cron is.

For a one-off schedule change without touching the standing cron (e.g. "shut
down early tonight" or "start up now instead of waiting for 05:00"), use the
`cluster-shutdown-at HH:MM` / `cluster-startup-at HH:MM` skills instead of
editing crontab by hand — see "One-off schedule override" below.

## Implementation

| File | Purpose |
|------|---------|
| `scripts/cluster-scheduler/night-off.sh` | 21:00 sequence: silence + drain/shutdown + power off (runs in the nazgul container) |
| `scripts/cluster-scheduler/morning-on.sh` | 05:00 sequence: power on + wait Ready + uncordon + SPIRE recycle (runs in the nazgul container) |
| `scripts/cluster-scheduler/shutdown-cluster.sh` | Graceful drain/cordon/shutdown, invoked by night-off.sh |
| `scripts/cluster-scheduler/silence-alerts.sh` | Alertmanager silence management (toggle, on/off, night, status) |
| `scripts/cluster-scheduler/cluster-kasa-outlet.py` | Kasa HS300 power strip control (`192.168.88.31`, ipc4-9 outlets) |
| `scripts/cluster-scheduler/pushover-alert.sh` | Direct out-of-band failure notification, bypasses Alertmanager entirely |
| `scripts/cluster-scheduler/Remfile` | Builds `localhost:5004/cluster-scheduler:latest` (python-kasa + kubectl + openssh-client + curl) |
| `scripts/cluster-night-off.sh` / `scripts/cluster-morning-on.sh` | Manual convenience wrappers, runnable from omen — not the automation itself |
| `/etc/cluster-scheduler/` on nazgul | kubeconfig (`ipc-vip` → `192.168.88.58:6443`), pushover.env, `crontab.default` cache, container build context |
| `/root/.ssh/id_rsa` on nazgul | omen's SSH key, bind-mounted into the container for direct-IP SSH to nodes |
| `/var/log/cluster-scheduler.log` on nazgul | stdout/stderr of every cron-triggered run — check here first for any scheduler issue |

Rebuild the container after changing anything in `scripts/cluster-scheduler/`:

```bash
rsync -a scripts/cluster-scheduler/ root@nazgul.taildd208.ts.net:/etc/cluster-scheduler/build/
ssh root@nazgul.taildd208.ts.net "cd /etc/cluster-scheduler/build && pelagos build -t localhost:5004/cluster-scheduler:latest -f Remfile . && pelagos image push --insecure localhost:5004/cluster-scheduler:latest"
```

## One-off schedule override

Two Claude Code skills, backed by `set-shutdown-time.sh` / `set-startup-time.sh`
in `scripts/cluster-scheduler/`, let you defer/advance tonight's shutdown or
startup without permanently changing the standing 21:00/05:00 cron:

- **`cluster-shutdown-at HH:MM`** — installs a one-off crontab entry for
  today only that runs the shutdown at HH:MM instead of 21:00, chained with
  a restore of the cached canonical crontab
  (`/etc/cluster-scheduler/crontab.default` on nazgul) right after it fires.
  Refuses (exit 1) if HH:MM has already passed today.
- **`cluster-startup-at HH:MM`** — same one-off mechanism for morning-on.sh
  if HH:MM is still ahead today. If HH:MM has already passed, no
  scheduling — instead checks Kasa outlet power state for all 6 nodes and
  starts the cluster immediately if it isn't already up.
- **`get-schedule.sh`** — reports the effective shutdown/startup times from
  nazgul's live crontab (standard vs. active override); wired into the
  `check-cluster-health` skill, shown right after the health table.

Each invocation always rebuilds nazgul's crontab from the cached default +
the new override, so a stale prior override can never linger.

Skill files live outside this repo at `~/.claude/skills/{cluster-shutdown-at,
cluster-startup-at}/SKILL.md` — only the scripts are checked into git.

## History

- **2026-07-18**: first implementation — systemd timer (`cluster-night-off.timer`
  / `cluster-morning-on.timer`) on omen. First run was partially manual;
  ipc9 failed to start because of a leftover `debug.conf` drop-in (removed).
- **2026-07-18 (same day)**: migrated to nazgul cron + Pelagos container for
  reliability independent of omen's power/sleep state. The omen timer units
  were left on disk, **disabled**, rather than removed.
- **2026-07-24**: container rebuilt — removed an explicit `pelagos-cri`
  restart from morning-on.sh (it was orphaning DaemonSet pods by making
  kubelet recreate them while old processes kept running; plain systemd
  handles CRI startup cleanly on its own) and added the SPIRE agent
  recycling step.
- **2026-08-08**: added the `cluster-shutdown-at` / `cluster-startup-at`
  one-off override skills.
- **2026-08-15**: `silence-alerts.sh` failure was silently swallowed by a
  bash gotcha, aborting the whole night-off run with no notification — led
  directly to `pushover-alert.sh`'s direct, Alertmanager-independent design.
- **2026-08-19**: the long-dead, disabled omen systemd units were discovered
  during an unrelated troubleshooting session (checking cluster health after
  a SPIRE-related Pushover alert led to checking the wrong, stale automation
  path first) and deleted. This doc was rewritten to match the actual
  running architecture — it had been describing the superseded omen-timer
  design the whole time.
