# Cluster Night Mode

Automated nightly shutdown (21:00) and startup (05:00), timed to **Europe/London**
hours, to save power.

**2026-10-10: re-anchored from America/Los_Angeles (Seattle) to Europe/London** —
the owner relocated/travels with UK hours now being the relevant "awake" window.
This is a pure timezone change, same 8h-off/16h-on shape as before (see "Timezone"
below for exactly what had to change and why it's parametrized, not hardcoded).

## How it works

**Runs via root crontab on nazgul (always-on NAS), not omen.** The original
design (2026-07-18) used a systemd timer on omen, but omen is a laptop that
travels and sleeps — automation tied to it wasn't reliable. It was migrated
to nazgul-hosted cron jobs the same day; the omen timer units were left in
place, disabled, for weeks afterward and caused real confusion (see
"History" below) before being deleted 2026-08-19. **If you're looking for
this automation, it is on nazgul, not omen.**

Each cron line runs a one-shot Pelagos container built from
`scripts/cluster-scheduler/`. The crontab starts with a `CRON_TZ=` line (controls
when cron *fires* each job) and every `pelagos run` invocation also passes
`--env TZ=...` (controls what timezone the container's own internal date
arithmetic -- specifically `silence-alerts.sh`'s "night"/"wake_time" math --
resolves against). **Both must be changed together** when the power-cycle
timezone changes; they're independent settings that happen to need the same
value, not one setting duplicated for no reason:

```
CRON_TZ=Europe/London
0 21 * * * pelagos run --rm --network=bridge --env TZ=Europe/London \
    --bind-ro /root/.ssh/id_rsa:/root/.ssh/id_rsa \
    --bind-ro /etc/cluster-scheduler/kubeconfig:/etc/cluster-scheduler/kubeconfig \
    --env-file /etc/cluster-scheduler/pushover.env \
    localhost:5004/cluster-scheduler:latest /scripts/night-off.sh \
    >> /var/log/cluster-scheduler.log 2>&1

0 5 * * * pelagos run --rm --network=bridge --env TZ=Europe/London ... /scripts/morning-on.sh >> /var/log/cluster-scheduler.log 2>&1
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

### `shutdown-cluster.sh` failing should now be rare — and never leaves the cluster up

Before 2026-10-10, a single stuck `kubectl drain` call (typically a race
against `virt-operator` recreating `virt-api-pdb`/`virt-controller-pdb`
faster than it could be deleted — see that script's own header comment for
the full history) would abort the entire script via `set -e`, **before any
node got `shutdown -h now`** — the whole cluster stayed powered on all
night, only discovered the next morning. This happened for real on
2026-10-09/10 for `ipc4` specifically.

Fixed two ways, not just a retry: `kubectl drain` now passes
`--disable-eviction` (bypasses PodDisruptionBudget checking entirely,
which is the *semantically correct* choice for a full-cluster shutdown —
there's no "other replica to shift load to" when nothing survives, so
honoring PDBs here never actually bought anything but risk), AND every
cordon/drain call tolerates its own failure and continues rather than
aborting the script. The explicit design goal (owner's direction,
2026-10-10): a single node's drain misbehaving must never be the reason
the whole cluster stays powered on overnight — every node still gets
`shutdown -h now` regardless of how cleanly (or not) it drained first. A
degraded drain logs a WARNING (visible in `/var/log/cluster-scheduler.log`
and in the final "Done" line's count) but is no longer treated as a
failure requiring Pushover — `shutdown-cluster.sh` failing outright should
now be reserved for genuinely exceptional cases (kubectl/ssh binaries
missing, a true script bug), not an expected-and-tolerated PDB race.

## Timing

All times **Europe/London** (see "Timezone" below).

| Time  | Event |
|-------|-------|
| 21:00 | Silence created (expires 05:30), graceful drain starts |
| 21:05-21:10 | All nodes OS-shutdown, Kasa power cut |
| 05:00 | Kasa power restored, nodes boot |
| 05:02-05:05 | k3s up, nodes Ready, SPIRE agents recycled |
| 05:05-05:15 | Pods scheduled and Running |
| 05:30 | Silence expires — alerts live again |

## Timezone

Two independent settings control this, and both have to change together if the
power-cycle timezone ever changes again:

1. **`CRON_TZ=Europe/London`** — the first line of nazgul's crontab (and of
   `/etc/cluster-scheduler/crontab.default`, the cached copy the one-off
   override skills rebuild from). Controls when cron *fires* `night-off.sh`/
   `morning-on.sh`/`descheduler-alert.sh` — e.g. `0 21 * * *` now means 21:00
   London time, not 21:00 wherever nazgul's own system clock happens to be set
   (that's still `America/Los_Angeles` at the OS level — deliberately untouched,
   since other things on nazgul may reasonably assume the system clock).
2. **`--env TZ=Europe/London`** on every `pelagos run` invocation in that same
   crontab — controls what timezone the *container's* own internal date
   arithmetic resolves against. Specifically `silence-alerts.sh`'s "night"/
   "wake_time" math (e.g. "05:30 today"): the container runs with system
   `TZ=UTC` by default, and that script needs to know what "05:30" means in
   the same terms the cron-fire-time is anchored to, or the silence window
   drifts out of alignment with the actual shutdown/startup times.

**This is parametrized, not hardcoded** — changing the timezone again is a
crontab-only edit (update both the `CRON_TZ=` line and every `--env TZ=...`
flag), no image rebuild needed. It wasn't always this way: `silence-alerts.sh`
originally had `export TZ="America/Los_Angeles"` baked into the script itself,
which meant the timezone was a value living inside a *built container image* —
changing it required a full rsync+build+push cycle just to change one string.
Fixed 2026-10-10 (prompted by exactly that friction during the London move):
the script now reads `export TZ="${TZ:-Europe/London}"`, honoring whatever the
caller's environment already provides and only falling back to a default if
not. The *crontab* (not the image) is now the single source of truth for the
power-cycle timezone.

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
from omen. They are **not** what runs automatically; nazgul's cron is.

**Correction 2026-10-10, this was previously wrong here:** these wrappers do
**not** call the nazgul container's `silence-alerts.sh`/`shutdown-cluster.sh`/
`cluster-kasa-outlet.py` over SSH — `cluster-night-off.sh` calls
`"$SCRIPT_DIR/silence-alerts.sh"`, which resolves to a **separate, independent
top-level copy** (`scripts/silence-alerts.sh`, not
`scripts/cluster-scheduler/silence-alerts.sh`) that runs locally on whatever
machine invokes it, not in the nazgul container at all. This copy had drifted
substantially from the cluster-scheduler one (158 lines vs 238 as of
2026-10-10) before today's fix — both got the same no-arg-toggle removal
patched in, but the broader drift (missing fixes/features accumulated in one
copy but not the other) is unresolved and worth a deliberate decision (retire
one in favor of a thin wrapper around the other, most likely) rather than
assuming they'll stay in sync on their own. Also worth checking: `cluster-
kasa-outlet.py off all` in this same manual path hits the Kasa strip's LAN-only
IP directly — like `cluster-morning-on.sh` already demonstrated 2026-10-10,
this whole manual-wrapper path probably doesn't work at all when run from
somewhere off the home LAN (e.g. while traveling), unlike the actual cron
automation (which always runs from nazgul, on the LAN).

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
| `scripts/silence-alerts.sh` | **Separate, independent copy** of `cluster-scheduler/silence-alerts.sh` used by the manual wrappers above (not a thin wrapper around it) — drifted apart from the real one, unresolved as of 2026-10-10, see the correction note above |
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
- **2026-10-10**: re-anchored the power cycle from America/Los_Angeles to
  Europe/London (owner relocated). While doing this, found and fixed a real
  footgun: `silence-alerts.sh` had a bare-no-argument default that silently
  toggled the current silence on/off depending on hidden state — removed
  (now a usage error) after it bit exactly this way during the same session
  (an unrelated sanity-check command accidentally untoggled a real,
  legitimate night silence). Also found the timezone was hardcoded inside
  the script itself, requiring a full container rebuild to change — reworked
  to read from the environment (`--env TZ=...` on the crontab's `pelagos run`
  line) so future timezone changes are crontab-only. Separately discovered
  (not yet resolved) that the manual-override wrappers
  (`cluster-night-off.sh`/`cluster-morning-on.sh`) use a completely separate,
  independently-drifted copy of `silence-alerts.sh` at the top level of
  `scripts/`, not the nazgul container's copy as this doc previously (and
  wrongly) claimed — see the Implementation table and the correction note
  under Manual override.
