# SSH `setlocale: LC_CTYPE: cannot change locale ('')` warning

## Symptom

Every SSH login to an ipc node prints:

```
bash: warning: setlocale: LC_CTYPE: cannot change locale (''): No such file or directory
```

## Root cause

Ubuntu's default `sshd_config` ships `AcceptEnv LANG LC_* COLORTERM NO_COLOR`,
forwarding whatever `LC_*` variables the client happens to have set —
including an *empty* one. Confirmed 2026-09-29 via `/proc/<pid>/environ` on a
live session: a client-side interactive shell (zsh + Powerlevel10k, likely
tied to its gitstatus/instant-prompt locale handling — not fully traced to
an exact line, and not necessary to) can end up with `LC_CTYPE` exported as
an empty string rather than simply unset. `ssh`'s `SendEnv LC_*` (in
`~/.ssh/config`) forwards it faithfully, and glibc/bash fail trying to
`setlocale()` an empty name — even though `LANG` alone is already sufficient
on every ipc node (all six have `en_US.utf8` installed,
`LANG=en_US.UTF-8` in `/etc/default/locale`). A clean test sending only
`LANG` resolves the full locale correctly with no warning.

## Fix

Narrow `AcceptEnv` on every node from `LANG LC_*` to just `LANG` (keeping
`COLORTERM NO_COLOR`, which are unrelated and harmless). This makes every
node immune to *any* client forwarding a bad `LC_*` value — including a
future client we haven't debugged yet — rather than relying on every
client's shell config staying clean.

Applied live to all six nodes (`sed -i`, then `sudo systemctl reload ssh` —
no connection drop, no k3s/pelagos-cri restart needed) and folded into
`scripts/install-pelagos.sh` (idempotent `sed`, runs as part of the normal
per-node config deployment step) so it survives future reinstalls rather
than needing to be reapplied by hand. See the comment block above the
`AcceptEnv` step in that script for the full inline explanation.
