# Cluster Night Mode

Automated nightly shutdown (21:00) and morning startup (05:00) to save power.

## How it works

**21:00 — `cluster-night-off.sh` (systemd timer on omen)**

1. `silence-alerts.sh night 05:30` — creates an Alertmanager silence until 05:30
2. `shutdown-cluster.sh` — cordons all nodes, drains workers, drains control plane,
   sends `shutdown -h now` in order (workers → ipc5/6 → ipc4)
3. Waits 60s for nodes to fully power off
4. `cluster-kasa-outlet.py off all` — cuts power to all six outlet slots

**05:00 — `cluster-morning-on.sh` (systemd timer on omen)**

1. `cluster-kasa-outlet.py on all` — restores power to all six nodes
2. k3s starts automatically as a systemd service on each node (no further action needed)

**05:30 — Silence auto-expires in Alertmanager**

The 30-minute grace window covers normal boot time (~10-15 minutes). If the cluster
isn't healthy by 05:30, alerts fire — you get paged. Every failure mode produces noise
rather than silence.

## Timing

| Time  | Event |
|-------|-------|
| 21:00 | Silence created (expires 05:30), graceful drain starts |
| 21:05-21:10 | All nodes OS-shutdown, Kasa power cut |
| 05:00 | Kasa power restored, nodes boot |
| 05:02-05:05 | k3s up, nodes Ready |
| 05:05-05:15 | Pods scheduled and Running |
| 05:30 | Silence expires — alerts live again |

## Manual override

```bash
# Power on now (cluster is off)
scripts/cluster-morning-on.sh

# Power off now (skips graceful drain — use shutdown-cluster.sh for graceful)
scripts/cluster-kasa-outlet.py off all

# Silence alerts manually for 4h (e.g. during maintenance)
scripts/silence-alerts.sh on 4h

# Check silence state
scripts/silence-alerts.sh status

# Disable nightly automation temporarily
sudo systemctl stop cluster-night-off.timer cluster-morning-on.timer

# Re-enable
sudo systemctl start cluster-night-off.timer cluster-morning-on.timer
```

## Implementation

| File | Purpose |
|------|---------|
| `scripts/cluster-night-off.sh` | 9pm sequence: silence + shutdown + power off |
| `scripts/cluster-morning-on.sh` | 5am sequence: power on |
| `scripts/silence-alerts.sh` | Alertmanager silence management (toggle, on/off, night, status) |
| `scripts/cluster-kasa-outlet.py` | Kasa HS300 power strip control (ipc4-9 outlets only) |
| `/etc/systemd/system/cluster-night-off.{timer,service}` | Systemd timer on omen, WakeSystem=yes |
| `/etc/systemd/system/cluster-morning-on.{timer,service}` | Systemd timer on omen, WakeSystem=yes |

## Notes

- `WakeSystem=yes` in the timer units wakes omen from suspend at the scheduled time.
  If omen is fully powered off (not suspended), the timer fires when omen next boots
  (`Persistent=true` means it catches up on missed runs at next boot).
- The Kasa HS300 is at `192.168.88.16`. Each node (ipc4-9) is a named outlet slot.
- `silence-alerts.sh night` defaults to 05:30 expiry; pass a different time to override:
  `silence-alerts.sh night 06:00`.
- Check timer status: `sudo systemctl list-timers cluster-*`
- Check last run logs: `journalctl -u cluster-night-off.service` or `cluster-morning-on.service`
