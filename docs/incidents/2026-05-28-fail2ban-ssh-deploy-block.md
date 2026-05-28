---
title: Deploy to NL blocked by fail2ban SSH ban (wrong key → failed auths)
date: 2026-05-28
status: resolved
severity: P4
duration: ~1h deploy blocked (NO user impact — prod stayed fully up)
tags: [deploy, ssh, fail2ban, nl, infra, postmortem]
---

# Incident: `./deploy.sh nl` blocked by fail2ban SSH ban

## Symptom

`./deploy.sh nl` failed immediately after the local Go cross-compile:

```
>>> Binary ready: 23M
Connection closed by 147.45.252.234 port 22
```

`ssh root@147.45.252.234` reproduced it: TCP to `:22` connected, but the
session closed at `kex_exchange_identification: Connection closed by remote
host` — **before** key exchange / auth, with no SSH banner, 100% consistent.

**Prod was never affected:** `api.madfrog.online` → 200, apex → 200, VPN
:443 open the whole time. Only outbound SSH from the operator's IP was blocked.

## Root cause

The operator Mac had the correct deploy key on disk
(`~/.ssh/claude-code-ssh-key`, Timeweb ssh-key id 557329, authorized on NL
server 6379091) but it was **not in use**: ssh-agent was empty and `~/.ssh/config`
had no entry for `147.45.252.234`. So `ssh root@147.45.252.234` offered the
wrong default keys (`id_ed25519` etc.), which NL rejected → repeated
`Permission denied (publickey)`. deploy.sh fires several SSH/rsync/scp
connections per run, so a deploy attempt produced a burst of failed auths →
**fail2ban `sshd` jail banned the IP** (jail counters: 1946 total failed, 342
total banned over the box's life).

A banned IP's connection is accepted at TCP then dropped before the SSH
banner — exactly the `kex_exchange_identification` signature, which is easy to
misread as a server/network fault. It is not: TCP connecting + no banner +
100% consistent + per-IP = an application-layer IP ban.

## Diagnosis (how we proved it was a ban, not a dead server)

Without SSH, queried NL's own telemetry via the Grafana → Prometheus API
(Grafana is behind Cloudflare, which 1010-blocks non-browser User-Agents — use
a browser UA). node-exporter showed the box healthy: uptime ~30h, CPU 13%,
load 0.17, RAM 68% (630 MiB free), disk 34%, 0 blocked procs. That ruled out
the only competing hypothesis (sshd failing to fork under resource pressure) →
the SSH refusal was a deliberate per-IP ban.

## Resolution

1. **Pinned the right key** in `~/.ssh/config` so ssh stops offering wrong keys:
   ```
   Host 147.45.252.234 chameleon-nl nl
       HostName 147.45.252.234
       User root
       IdentityFile ~/.ssh/claude-code-ssh-key
       IdentitiesOnly yes
   ```
   `IdentitiesOnly yes` is the key fix — it prevents the failed-auth burst that
   trips fail2ban in the first place.
2. **Deployed from a different IP** (phone hotspot) — fresh, unbanned IP; the
   pinned key authenticated first try. `deploy.sh nl` → `Backend is healthy!`.
3. The original ban (sshd jail, default bantime) had **auto-expired** by the
   time we checked — `fail2ban-client status sshd` showed 0 currently banned,
   ipset/iptables/hosts.deny all clean.

## Prevention / lessons

- The `~/.ssh/config` pin above is permanent → future deploys auth cleanly,
  no new bans.
- If ever banned again: deploy from another IP (hotspot), or unban via the
  Timeweb web-VNC console (`root` login, password in secret
  `CHAMELEON_NL2_ROOT_PASSWORD`) with `fail2ban-client set sshd unbanip <IP>`.
  The Timeweb API has no console/command endpoint — its only lever is a full
  reboot (disruptive; avoid for an unban).
- `kex_exchange_identification: Connection closed` with TCP connecting is a
  ban signature, not a server outage — verify box health via Grafana/Prometheus
  before assuming the worst.
