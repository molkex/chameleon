# MSK relay — nginx config (DR snapshot)

The MSK relay (`217.198.5.52`, Tatarstan-On-Line) plays two roles:

1. **API front** for `api.madfrog.online` — RU users hit MSK (NOT Cloudflare, to
   dodge CF throttling), nginx proxies to NL:80. Sets `X-Forwarded-For` /
   `X-Real-IP` so NL's `set_real_ip_from` resolves the real client (see
   `backend/internal/api/server.go` SEC-02). Includes the SSE location for the
   support chat (`/api/(v1/)?mobile/support/stream`).
2. **sing-box VPN chains** — `nl-via-msk` (:2097) and `fr-via-msk` (:2099). These
   live in sing-box's own config on the box (`/etc/sing-box/config.json`), which
   carries Reality private keys + user UUIDs and is therefore **NOT committed
   here**. Reference only; recover from the encrypted box backup, not git.

## Files (no secrets — safe to track)

| File | On the box |
|---|---|
| `api.madfrog.online.conf` | `/etc/nginx/sites-available/api.madfrog.online` |
| `nginx.conf` | `/etc/nginx/nginx.conf` (main; includes sites-enabled + conf.d) |

## Sync flow (this is a SNAPSHOT, the box is the source of truth)

These were historically edited live on the box (the audit 2026-06-17 flagged the
DR gap). Workflow:

```bash
# Pull live → repo (run from repo root):
ssh -i ~/.ssh/claude-code-ssh-key root@217.198.5.52 \
  'cat /etc/nginx/sites-available/api.madfrog.online' > infrastructure/msk-relay/api.madfrog.online.conf

# Restore repo → box (after a box rebuild), then reload:
scp infrastructure/msk-relay/api.madfrog.online.conf \
  root@217.198.5.52:/etc/nginx/sites-available/api.madfrog.online
ssh root@217.198.5.52 'nginx -t && systemctl reload nginx'
```

Drift check: `diff <(ssh root@217.198.5.52 cat /etc/nginx/sites-available/api.madfrog.online) infrastructure/msk-relay/api.madfrog.online.conf`

> Snapshotted 2026-06-17 (RELAY-CONFIGS-IN-REPO). Re-pull after any live nginx edit.
