---
title: Ops runbook — cron, watchdog, backups, add-node, diagnostics
date: 2026-06-01
status: active
tags: [ops, cron, watchdog, backup, diagnostics, playbook]
---

# Ops runbook

Day-2 operations for the live mesh. For the backend deploy itself see
[`deploy-nl.md`](deploy-nl.md); this file is everything *around* it.
Canonical node facts: [`../state/servers.yaml`](../state/servers.yaml),
snapshot: [`../state/project.yaml`](../state/project.yaml).

## Nodes at a glance

| Node | Role | SSH |
|---|---|---|
| NL `147.45.252.234` | backend + DB + VPN exit (sole authority) | `ssh -i ~/.ssh/claude-code-ssh-key root@147.45.252.234` |
| GRA `54.38.243.162` | 2nd VPN exit (France), VPN-only | `ssh -i ~/.ssh/claude-code-ssh-key debian@54.38.243.162` |
| MSK `217.198.5.52` | api front + VPN relay chains | `ssh -i ~/.ssh/claude-code-ssh-key root@217.198.5.52` |
| SPB `185.218.0.43` | TCP/whitelist-bypass relay | `sshpass -p "$SPRINTBOX_VPS_PASSWORD" ssh root@185.218.0.43` (password, not key) |

SSH to NL requires `claude-code-ssh-key` pinned with `IdentitiesOnly yes` or
fail2ban bans you — see [`deploy-nl.md`](deploy-nl.md#prerequisites).

## Cron inventory (NL)

Installed by `deploy.sh` (idempotent). All scripts under
[`../../backend/scripts/`](../../backend/scripts/):

| Cadence | Script | Purpose | Log / sentinel |
|---|---|---|---|
| `* * * * *` | [`singbox-watchdog.sh`](../../backend/scripts/singbox-watchdog.sh) | restart sing-box if container died | `/var/log/singbox-watchdog.log` |
| `* * * * *` | [`health-check.sh`](../../backend/scripts/health-check.sh) | alert if backend `/health` down | `/var/log/chameleon-health.log` |
| `0 3 * * *` | [`db-backup.sh`](../../backend/scripts/db-backup.sh) | daily pg_dump + offsite B2 | `/var/log/chameleon-backup.ok` |

Check what's actually installed: `ssh nl 'crontab -l'`.

## Watchdog + health-check behaviour (quiet-on-success)

Both run every minute and **log nothing on success** — a "frozen" log file is
healthy, not broken. They only write/alert when something is wrong.

- **`singbox-watchdog.sh`**: `docker ps | grep singbox`; if absent →
  `docker rm -f singbox`, `sudo test -f` the config (root-only path), re-run the
  same `docker run` as [`singbox-run.sh`](../../backend/scripts/singbox-run.sh),
  wait 3 s, Telegram alert "was down, restarted" or "FAILED to start".
- **`health-check.sh`**: curls backend `/health`; Telegram alert if unreachable,
  rate-limited to 1 alert / 5 min per problem.
- **Alerts** go through [`telegram-alert.sh`](../../backend/scripts/telegram-alert.sh),
  which reads `/etc/chameleon-alerts.env` (chmod 644 so the cron user can read).

## DB backup + offsite B2

`db-backup.sh` runs daily at 03:00: `pg_dump chameleon | gzip` to local
`/var/backups/chameleon/`, prunes >7 days, then pushes offsite to Backblaze B2
(creds in `~/.secrets.env`, sourced into the deploy env). On success it touches
`/var/log/chameleon-backup.ok`; if that sentinel is older than 30 h, MON-02 alerts.
Restore: gunzip the dump and `psql chameleon < dump.sql` (forward-only — never
drop the table to "fix" a bad migration).

## Add a new VPN exit / node

The mesh now syncs the active user set to exits via the User API (no per-deploy
key juggling — see [`../incidents/2026-05-31-gra-france-user-sync.md`](../incidents/2026-05-31-gra-france-user-sync.md)).

1. Provision the box (Ubuntu/Debian 22+), install Docker, open firewall:
   `ufw allow 443/tcp` (VLESS), plus `443/udp` if Hysteria2.
2. Generate Reality keypair; run sing-box as a standalone container via
   [`singbox-run.sh`](../../backend/scripts/singbox-run.sh) (never in compose).
3. Validate before any client test: `sing-box check -c <config>.json` on the box.
4. Bind the User API to `0.0.0.0:15380`, `ufw allow` **only** from NL
   `147.45.252.234`, protect with `USER_API_SECRET` (bearer).
5. Insert the row in NL Postgres `vpn_servers` (`key`, `host`, `country_code`,
   `reality_public_key`, `user_api_url=http://<ip>:15380`). NL's RelayUserSyncer
   then pushes the active user set every 30 s + on each registration.
6. Confirm the exit appears in a fresh `/api/v1/mobile/config` and that
   `whoer`/`ifconfig.me` shows the expected exit IP.

⚠️ `vpn_servers` rows are **not** propagated by cluster sync — edit them on NL
directly. New relay/exit ports also need a matching `ufw allow` on every relay
that forwards to them.

## Diagnostics quick-reference

```bash
# Backend health (NL nginx listens :80/:443; chameleon Echo :8000 inside)
ssh nl 'curl -s localhost:8000/health'          # {"status":"ok"}

# sing-box up? logs?
ssh nl 'docker ps | grep singbox; docker logs singbox --tail 20'

# VPN inbound listening (NL VLESS is :443, NOT :2096)
ssh nl 'ss -tlnp | grep :443'

# User API reachable (zero-downtime user mgmt)
ssh nl 'curl -s -H "Authorization: Bearer $USER_API_SECRET" localhost:15380/api/v1/inbounds'

# Live traffic / connections (UI source, not accounting — see debug-vpn-ios.md)
ssh nl 'curl -s localhost:9090/connections'

# Relay user-sync to GRA
ssh nl 'docker logs chameleon 2>&1 | grep -iE "relay|sync" | tail -20'
```

### Restart sing-box without dropping other sessions

```bash
ssh nl 'cd /opt/chameleon/backend && ./scripts/singbox-run.sh --force'
```

### Reload users without restarting sing-box

`POST /api/v1/admin/nodes/sync` (admin JWT) — re-pushes the user set via User API,
SIGHUP fallback.

**Never** `docker compose down --remove-orphans` or `up` without `--no-deps` —
either kills the standalone sing-box container. See [`deploy-nl.md`](deploy-nl.md).
