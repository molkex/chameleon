---
title: Deploy backend to NL
date: 2026-05-28
status: active
tags: [deploy, nl, backend, playbook]
---

# Deploy backend to NL

NL is the sole production node (see [`../decisions/0004-single-nl-spof.md`](../decisions/0004-single-nl-spof.md)). Standard backend deploy uses `backend/deploy.sh`.

**Critical:** deploys never touch sing-box by default. VPN sessions survive backend restarts.

## Prerequisites

- SSH key for `root@147.45.252.234` (Timeweb NL).
- `~/.secrets.env` sourced (contains `ASC_*` keys, B2 credentials for backups).
- Backend code committed (deploy.sh rsync's the working tree).

## Standard deploy (backend + admin SPA only)

```bash
cd backend
./deploy.sh nl
```

What it does:

1. Builds Go binary locally (NL has 2 GB RAM, can't compile Go in Docker).
2. Builds nginx container with admin SPA bundle baked in (vite build).
3. rsync's binary + compose + nginx config to `/opt/chameleon` on NL.
4. Runs pending migrations (`backend/migrations/*.sql`) via psql.
5. `docker compose up -d --force-recreate` for `chameleon` + `chameleon-nginx`.
6. Waits for `/health` 200 within 8 s.
7. Prints `=== Done: nl deployed ===` on success.

## Including sing-box restart

**Only when sing-box config itself changed** (rare — new server, new SNI, key rotation):

```bash
./deploy.sh nl --with-singbox
```

⚠️ This drops all active VPN sessions for the duration of the restart (~3-5 s). Schedule for low-traffic window.

## What touches what

- `migrations/*.sql` — applied automatically.
- `infrastructure/spb-relay/*.conf` — NOT deployed by this script. SPB nginx is updated manually (`scp` + `nginx -s reload` on SPB box).
- `clients/admin/` — bundled into nginx image automatically (vite build inside the script).
- iOS app — separate flow, see [`ios-cli-release.md`](ios-cli-release.md).

## Verify after deploy

```bash
# Health
ssh root@147.45.252.234 'curl -s localhost:8080/health'
# expect: {"status":"ok"}

# Migration applied
ssh root@147.45.252.234 \
  'docker exec chameleon-postgres psql -U chameleon -d chameleon -c "SELECT max(version) FROM schema_migrations"'

# Auth gates still 401-ing on protected endpoints
curl -s -o /dev/null -w '%{http_code}\n' https://api.madfrog.online/api/v1/admin/users
# expect: 401
```

## Rollback

If the new binary panics on startup:

```bash
ssh root@147.45.252.234
cd /opt/chameleon
git -C / log /opt/chameleon -1   # find last working tag
docker compose pull              # pull previous image (if tagged)
# OR: re-run deploy.sh from a known-good commit locally
```

For a migration that broke things, **don't** drop the table — write a forward-only migration that reverses the issue.

## Common gotchas

- **MED-015 risk:** if you save a server via admin SPA Servers tab with empty `reality_private_key`, the next deploy will wipe the key and break sing-box startup. Backend now COALESCE-NULLIF-guards this (see [`../incidents/2026-05-27-med-015-restart-loop.md`](../incidents/2026-05-27-med-015-restart-loop.md)), but be careful.
- **Bind-mount targets:** `/var/log/singbox-events.jsonl` and `/etc/chameleon/asc-key.p8` must exist BEFORE `docker compose up`. deploy.sh pre-touches them; don't bypass.
- **Backblaze B2 backup:** db-backup.sh runs daily via cron. Sentinel: `/var/log/chameleon-backup.ok`. If age > 30h, MON-02 alerts.
