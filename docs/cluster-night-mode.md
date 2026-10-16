# Cluster Night Mode

Automated nightly shutdown (21:00) and startup (05:00), timed to **Europe/London**
hours, to save power.

**2026-10-10: re-anchored from America/Los_Angeles (Seattle) to Europe/London** —
the owner relocated/travels with UK hours now being the relevant "awake" window.
Same 8h-off/16h-on shape as before. See "Timezone" below for how this is
actually implemented (a minute-by-minute tick script, not a cron-native
timezone feature — that approach was tried first and silently didn't work;
the full story is there since it's genuinely non-obvious).

## How it works

**Runs via root crontab on nazgul (always-on NAS), not omen.** The original
design (2026-07-18) used a systemd timer on omen, but omen is a laptop that
travels and sleeps — automation tied to it wasn't reliable. It was migrated
to nazgul-hosted cron jobs the same day; the omen timer units were left in
place, disabled, for weeks afterward and caused real confusion (see
"History" below) before being deleted 2026-08-19. **If you're looking for
this automation, it is on nazgul, not omen.**

nazgul's crontab has exactly one line, firing every minute:

```
* * * * * /etc/cluster-scheduler/scheduler-tick.sh >> /var/log/cluster-scheduler.log 2>&1
```

`scheduler-tick.sh` (`scripts/cluster-scheduler/scheduler-tick.sh` in git,
deployed to that exact host path — it runs directly on nazgul, **not** inside
the Pelagos container) does the actual time-of-day decision: it checks the
current wall-clock time via `TZ=Europe/London date`, and only when that falls
in a 5-minute grace window around 21:00/05:00/05:20 does it launch the real
one-shot Pelagos container (`localhost:5004/cluster-scheduler:latest`,
`/scripts/night-off.sh` / `morning-on.sh` / `descheduler-alert.sh`), guarded
by a same-day marker file (`/etc/cluster-scheduler/.last-night-off` etc.) so
it fires exactly once per day even though many ticks land inside that window.
See "Timezone" below for why it's built this way instead of cron firing
directly at `0 21 * * *`.

(`crontab -l` and `cat /etc/cluster-scheduler/scheduler-tick.sh` on nazgul as
root are the live source of truth — this doc can drift, those can't.)

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

**First attempt (didn't work, left here so it isn't retried): `CRON_TZ=`.**
Many cron implementations (cronie/Fedora/RHEL's default) support a `CRON_TZ=`
line at the top of a crontab that controls what timezone the time fields are
interpreted in. Debian's stock `cron` package — what nazgul actually runs —
**does not support this at all**: its own `crontab(5)` man page says a `TZ=`
line "will affect only the commands executed in the crontab, not the
execution of the crontab tasks themselves." A bare `NAME=value` crontab line
just becomes an environment variable handed to the job; nothing in this cron
binary treats `CRON_TZ` specially. This was deployed believing it worked
(verified only that `crontab -l` echoed the line back, not that the actual
firing time had shifted) and genuinely didn't — `night-off`/`morning-on` kept
firing on nazgul's real system clock (`America/Los_Angeles`) the whole time,
discovered 2026-10-11 when a shutdown fired at the Pacific-equivalent wall
time instead of London time. `cronie` would fix this properly but is
Debian-experimental-only, not available on bookworm without adding an
unstable repo to this NAS's base OS — rejected. Changing nazgul's own system
timezone was also considered and explicitly rejected (shared US-based
machine; other things on it may reasonably assume the system clock). A third
option — hardcode the Pacific-clock-time equivalent of 21:00/05:00 London
directly into the crontab's numeric fields — was rejected too: UK and US DST
transitions land on different calendar dates, so a fixed offset is wrong for
about two weeks every spring and autumn until manually corrected.

**What actually runs: a once-a-minute tick, TZ-aware entirely inside the
script.** nazgul's crontab fires `scripts/cluster-scheduler/scheduler-tick.sh`
every minute (see "How it works" above) — a plain host-side script, not
containerized, cheap enough that running it 1440 times a day costs nothing
meaningful. It computes the current time via `TZ=Europe/London date`, which
resolves correctly through tzdata regardless of nazgul's own system timezone
and handles UK DST transitions automatically and permanently — no twice-a-year
manual correction, ever. Only when that falls inside a 5-minute grace window
around 21:00, 05:00, or 05:20 does it launch the real (heavy, Pelagos-based)
automation, guarded by a same-day marker file
(`/etc/cluster-scheduler/.last-night-off` etc.) so it fires exactly once per
day despite many ticks landing inside each window. The grace window (not an
exact-single-minute match) is deliberate: a transient hiccup exactly at `:00`
shouldn't skip the whole day's action.

Every `pelagos run` invocation the tick script launches still passes
`--env TZ=Europe/London` — a separate, independent setting from the above,
controlling what timezone the *container's own* internal date arithmetic
resolves against (specifically `silence-alerts.sh`'s "night"/"wake_time" math,
e.g. "05:30 today" — the container runs with system `TZ=UTC` by default).
**This is parametrized, not hardcoded**, for the same reason as before:
`silence-alerts.sh` used to have `export TZ="America/Los_Angeles"` baked into
the script itself (a value living inside a *built container image* — changing
it meant a full rsync+build+push cycle just to change one string), now reads
`export TZ="${TZ:-Europe/London}"` instead, honoring whatever the caller
provides. Changing the power-cycle timezone again means editing
`scheduler-tick.sh`'s three window-checks and its `--env TZ=...` flags (one
file, one host-side deploy via `rsync`, no crontab syntax to fight with and no
image rebuild unless the surrounding script logic itself changes too).

**Known gap from this exact transition (2026-10-11):** when a scheduling
mechanism is replaced mid-day, any window for *that specific day* that falls
*before* the replacement takes effect is lost — the new tick script has no
way to know a now-removed old mechanism was *about* to (incorrectly) handle
it. This happened for real: the `CRON_TZ` mechanism's broken 05:00-PDT
morning-on (= 13:00 BST) was deleted before it could fire, but the new
script's own correct 05:00-BST window had already passed hours earlier that
same morning — the cluster sat off with nothing scheduled to turn it back on
until the next day. Caught live and fixed with one manual `morning-on.sh`
invocation; nothing to do differently next time short of also checking
"is the cluster currently in the state today's schedule says it should be in"
immediately after deploying any scheduling change, not just after a scheduled
cron firing.

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
2026-10-10) — both got the same no-arg-toggle removal patched in that day,
but the broader drift (missing fixes/features accumulated in one copy but
not the other: the 2026-08-15 `set -e`/command-substitution error-handling
fix, `curl --max-time` timeouts, explicit `TZ=` pinning) wasn't closed yet.

**Resolved 2026-10-16**, deliberately: kept both copies (the alternative —
making the manual wrappers SSH into nazgul and call the real one — was
considered and explicitly rejected, since the whole point of this copy is
to work standalone, without a network dependency, from whatever machine
you're actually on). Backported the missing fixes into
`scripts/silence-alerts.sh` instead: `set -uo pipefail` (not `-e`) with
the same return-based error handling as the container copy, `curl --max-time
10` throughout, and `export TZ="${TZ:-Europe/London}"`. Also fixed a
real portability gap found while doing this: the script's date arithmetic
uses GNU `date -d` syntax, which doesn't exist on BSD/macOS `date` at
all (confirmed directly — the project's own working machines include both
omen, x86_64 Linux, and an Apple Silicon Mac). Now detects GNU-compatible
`date` or falls back to `gdate` (Homebrew's `coreutils` package on macOS),
erroring clearly if neither is present rather than failing with a cryptic
`date: illegal option` partway through. Both copies now carry a header
comment pointing at the other, so a future fix to one prompts checking
whether it belongs in both.

Separately, still unresolved: `cluster-kasa-outlet.py off all` in this
same manual path hits the Kasa strip's LAN-only IP directly — like
`cluster-morning-on.sh` already demonstrated 2026-10-10, this whole
manual-wrapper path probably doesn't work at all when run from somewhere
off the home LAN (e.g. while traveling), unlike the actual cron automation
(which always runs from nazgul, on the LAN).

For a one-off schedule change without touching the standing cron (e.g. "shut
down early tonight" or "start up now instead of waiting for 05:00"), use the
`cluster-shutdown-at HH:MM` / `cluster-startup-at HH:MM` skills instead of
editing crontab by hand — see "One-off schedule override" below.

## Implementation

| File | Purpose |
|------|---------|
| `scripts/cluster-scheduler/scheduler-tick.sh` | What cron actually calls, every minute — runs **directly on nazgul's host**, not in the container; TZ-aware gate deciding whether to launch night-off.sh/morning-on.sh/descheduler-alert.sh right now |
| `scripts/cluster-scheduler/night-off.sh` | 21:00 sequence: silence + drain/shutdown + power off (runs in the nazgul container) |
| `scripts/cluster-scheduler/morning-on.sh` | 05:00 sequence: power on + wait Ready + uncordon + SPIRE recycle (runs in the nazgul container) |
| `scripts/cluster-scheduler/shutdown-cluster.sh` | Graceful drain/cordon/shutdown, invoked by night-off.sh |
| `scripts/cluster-scheduler/silence-alerts.sh` | Alertmanager silence management (toggle, on/off, night, status) |
| `scripts/cluster-scheduler/cluster-kasa-outlet.py` | Kasa HS300 power strip control (`192.168.88.31`, ipc4-9 outlets) |
| `scripts/cluster-scheduler/pushover-alert.sh` | Direct out-of-band failure notification, bypasses Alertmanager entirely |
| `scripts/cluster-scheduler/Remfile` | Builds `localhost:5004/cluster-scheduler:latest` (python-kasa + kubectl + openssh-client + curl) |
| `scripts/cluster-night-off.sh` / `scripts/cluster-morning-on.sh` | Manual convenience wrappers, runnable from omen — not the automation itself |
| `scripts/silence-alerts.sh` | **Separate, independent copy** of `cluster-scheduler/silence-alerts.sh` used by the manual wrappers above (not a thin wrapper around it) — intentional (portable, no SSH/container dependency), brought back to parity 2026-10-16, see the correction note above |
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
startup without permanently changing the standing 21:00/05:00 Europe/London
schedule:

- **`cluster-shutdown-at HH:MM`** — writes `/etc/cluster-scheduler/.override-night-off`
  on nazgul (`"$TODAY $HH:MM"`), which `scheduler-tick.sh` checks every
  minute and uses instead of the standard 21:00 window for as long as its
  date matches today. Refuses (exit 1) if HH:MM has already passed today
  (Europe/London).
- **`cluster-startup-at HH:MM`** — same mechanism, `.override-morning-on`,
  for `morning-on.sh` if HH:MM is still ahead today (Europe/London). If
  HH:MM has already passed, no override written — instead checks Kasa
  outlet power state for all 6 nodes and starts the cluster immediately if
  it isn't already up.
- **`get-schedule.sh`** — reports the effective shutdown/startup times
  (standard, or an active today-dated override) by reading those same two
  files on nazgul; wired into the `check-cluster-health` skill, shown right
  after the health table.

Each override is self-expiring, not actively reverted: it's dated to
*today* specifically, so tomorrow it simply no longer matches and
`scheduler-tick.sh` falls back to the standard window on its own (and
lazily deletes the stale file the next time it checks) — no restore step,
no stale-override-lingering failure mode, consistent with this project's
general preference for state over TTLs (see
[[feedback_state_based_not_ttl]]).

Skill files live outside this repo at `~/.claude/skills/{cluster-shutdown-at,
cluster-startup-at}/SKILL.md` — only the scripts are checked into git.

**History:** these three scripts were genuinely broken 2026-10-11 for a few
hours, in the same session that introduced `scheduler-tick.sh` — they used
to work by grepping crontab for `night-off.sh`/`morning-on.sh` lines to
build a one-off numbered crontab entry, and once the crontab became a
single `* * * * * scheduler-tick.sh` line, that had nothing left to find
(`set-shutdown-time.sh` would abort immediately via `set -e` on the failed
grep). Rewritten the same day against the override-file model described
above, and verified end-to-end (including the already-passed and
already-up fallback paths, and that a rejected past-time request doesn't
clobber an existing valid override) before being considered done.

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
- **2026-10-11**: the 2026-10-10 `CRON_TZ=Europe/London` fix turned out to be
  a no-op — Debian's stock `cron` package doesn't support `CRON_TZ` at all
  (confirmed via its own `crontab(5)` man page), so night-off/morning-on kept
  firing on nazgul's real system clock the whole time, just *labeled* in BST
  thanks to the separately-correct `--env TZ=...` fix. Discovered when a
  shutdown fired at the exact Pacific-equivalent wall-clock moment instead of
  21:00 London. Replaced with `scheduler-tick.sh`: cron now fires every
  minute (no TZ feature needed at all), and the script itself does a
  `TZ=Europe/London date` check with a 5-minute grace window and a
  once-per-day marker file, launching the real automation only when it
  actually matches. Also hit, live, the "replacing a schedule mid-day loses
  that day's not-yet-fired window" gap described above — the cluster sat off
  for several hours with nothing scheduled to turn it back on until caught
  and fixed manually. Also, separately, fixed `shutdown-cluster.sh`'s actual
  root-cause bug (the PDB-eviction race that caused the original "shutdown
  failed" alert this whole timezone investigation started from) —
  `--disable-eviction` on every drain call, plus every cordon/drain
  tolerating its own failure so a single node's drain can never again leave
  the whole cluster powered on overnight. See the dedicated subsection above
  for the full reasoning (PDBs protect availability during a *partial*
  disruption; that's meaningless when every node goes dark together).
