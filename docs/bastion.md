# Bastion Host Architecture

ipc1 is the only node directly reachable from outside the LAN (via Tailscale).
ipc2 and ipc3 accept SSH only from ipc1's LAN IP (192.168.88.53).

```
  omen (tailnet)
       │
       │ tailscale
       ▼
  ipc1 (192.168.88.53)  ←── bastion + control plane
       │
       │ SSH ProxyJump (TCP tunnel)
       ├──────────────────────────┐
       ▼                          ▼
  ipc2 (192.168.88.52)      ipc3 (192.168.88.54)
  worker — SSH from           worker — SSH from
  ipc1 only                   ipc1 only
```

## Setup

```
bash scripts/setup-cluster-ssh.sh
```

Or individually:
```
bash scripts/setup-bastion.sh
bash scripts/setup-workers.sh
```

All scripts are idempotent — safe to run multiple times.

## What Each Script Does

**`scripts/remote/configure-bastion.sh`** (runs on ipc1)
- Writes `/etc/ssh/sshd_config.d/10-bastion.conf`
- Enables `AllowTcpForwarding yes` (required for ProxyJump)
- Disables agent forwarding, tunneling, X11, gateway ports
- Reloads sshd if config changed

**`scripts/remote/configure-worker.sh`** (runs on ipc2/ipc3)
- Writes `/etc/ssh/sshd_config.d/10-bastion-lockdown.conf`
- Sets `AllowUsers cb@192.168.88.53` — only cb from ipc1 can authenticate
- Configures UFW:
  - Allow SSH from bastion only (192.168.88.53:22)
  - Deny SSH from all other sources
  - Allow kubelet API (10250/TCP) from LAN — required for k3s
  - Allow Flannel VXLAN (8472/UDP) from LAN — required for pod networking
  - Default: deny incoming, allow outgoing
- Enables UFW if not already active

## SSH Config for omen

Add to `~/.ssh/config`:

```
Host ipc1
    HostName ipc1.taildd208.ts.net
    User cb
    IdentityFile ~/.ssh/id_rsa

Host ipc2
    HostName ipc2
    User cb
    IdentityFile ~/.ssh/id_rsa
    ProxyJump ipc1

Host ipc3
    HostName ipc3
    User cb
    IdentityFile ~/.ssh/id_rsa
    ProxyJump ipc1
```

After adding this, `ssh ipc2` and `ssh ipc3` will jump through ipc1 automatically.

## Testing

Verify the lockdown is working:

After setup, direct SSH to ipc2 should be rejected:
```
ssh -i ~/.ssh/id_rsa cb@192.168.88.52
```
Expected: `Permission denied`

Access via bastion should work:
```
ssh ipc2 hostname
```
Expected: `ipc2`

## Recovery

**Scenario: ipc1 goes down and you need access to ipc2 or ipc3.**

ipc1 is a single point of failure for SSH access to the workers. Options:

1. **Physical console** — direct keyboard/monitor access to ipc2 or ipc3.

2. **Restore ipc1** — once ipc1 is back up, normal access resumes.

3. **Emergency key** — as a precaution, you can pre-authorize a second key directly on ipc2/ipc3 from a known-safe IP (e.g. your router's management IP). This key would bypass the bastion lockdown only for break-glass access.

4. **Temporarily relax the lockdown** — if you have console access, comment out the `AllowUsers` line in `/etc/ssh/sshd_config.d/10-bastion-lockdown.conf` and reload sshd.

## Port Reference

| Port | Protocol | Purpose | Required on workers |
|------|----------|---------|-------------------|
| 22 | TCP | SSH (bastion only) | Yes |
| 10250 | TCP | kubelet API | Yes |
| 8472 | UDP | Flannel VXLAN | Yes |
| 6443 | TCP | k3s API server | ipc1 only (outbound from workers) |
