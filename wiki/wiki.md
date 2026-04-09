# Chameleon Wiki Summary (for Claude context)

## Current Architecture (2026-04-10)

### Traffic Flow
```
iPhone (libbox 1.13.5)
  ├─ Proxy selector (user picks server)
  │   ├─ 🇩🇪 Germany      : 162.19.242.30:2096
  │   ├─ ���🇱 Netherlands  : 194.135.38.90:2096
  │   ├─ 🇷🇺 Russia → DE  : 185.218.0.43:443 (relay)
  │   ├─ 🇷🇺 Russia → NL  : 185.218.0.43:2098 (relay)
  │   └─ Auto (urltest, 3m interval, 100ms tolerance)
  │
  ├─ Route rules: sniff → hijack-dns → clash-direct → QUIC reject → ip_is_private
  ├─ DNS: DoH 1.1.1.1 (remote), DoH 8.8.8.8 (direct)
  └─ Protocol: VLESS Reality TCP, sing-box fork v1.13.6-userapi, SNI: ads.adfox.ru
```

### Servers
| Server | IP | VPN Port | VPN Engine | SSH |
|---|---|---|---|---|
| DE | 162.19.242.30 | 2096 | sing-box-fork v1.13.6-userapi | ubuntu@ (key auth) |
| NL | 194.135.38.90 | 2096 | sing-box-fork v1.13.6-userapi | root@ (key auth) |
| SPB Relay | 185.218.0.43 | 443, 2098 | nginx stream | — |

### Key Architecture Decisions (2026-04-10)

1. **sing-box runs OUTSIDE docker-compose** — standalone container via `scripts/singbox-run.sh`.
   Compose operations NEVER restart singbox / drop VPN connections.

2. **Reality keys stored in DB only** — `vpn_servers.reality_private_key` + `reality_public_key`.
   Backend reads at startup via `FindLocalServer(cluster.node_id)`. Single source of truth.

3. **User API** — custom sing-box fork with REST API on port 15380 for add/remove/list users
   without restart. Backend tries API first, falls back to SIGHUP.

4. **Watchdog** — `scripts/singbox-watchdog.sh` runs via cron every minute.
   Auto-restarts singbox if container dies. Sends Telegram alert on restart/failure.

5. **Cluster auth** — shared secret (Bearer token) on all `/api/cluster/*` endpoints.
   Config: `cluster.secret` in config.yaml / `CLUSTER_SECRET` env var.

6. **Mesh sync** — `vpn_servers` table synced between all nodes via cluster pull/push.
   Change keys/servers on any node → propagates to all peers (30s sync + instant pub/sub).
   Conflict resolution: "latest updated_at wins".

7. **Telegram alerts** — `scripts/health-check.sh` cron every minute checks API + singbox + VPN port.
   Alerts sent to admins on failure. Rate-limited: 1 per 5 min per issue.
   Config: `/etc/chameleon-alerts.env` (BOT_TOKEN + CHAT_IDS).

8. **DB backups** — `scripts/db-backup.sh` daily at 3:00 AM, pg_dump + gzip, 7-day retention.
   Alerts on backup failure.

### Deploy
```bash
./deploy.sh de          # deploy chameleon only (singbox untouched)
./deploy.sh nl          # same for NL
./deploy.sh all         # both servers
./deploy.sh de --with-singbox  # also restart singbox (brief VPN drop!)
```
Post-deploy checks: health API, singbox alive, User API, VPN port 2096, clash API.

### Critical Rules
1. **SNI**: ads.adfox.ru — never use google.com/cloudflare.com
2. **sing-box route rules ORDER**: `{"action":"sniff"}` MUST be first, then `{"protocol":"dns","action":"hijack-dns"}`
3. **DNS detour**: NOT needed in sing-box 1.13 — DNS servers go directly by default
4. **short_id**: use empty string `""` for new users (always valid). Random short_ids cause "reality verification failed"
5. **NEVER** run `docker compose down --remove-orphans` — it will kill standalone singbox
6. **Reality keys**: change in DB (`vpn_servers` table), restart chameleon to regenerate config, then restart singbox

### iOS Server Selection
- `selectServer()` modifies selector `default` in config JSON, saves to UserDefaults, disconnect → reconnect
- Config sources: 1) tunnel options (manual connect), 2) UserDefaults (on-demand), 3) file (fallback)

## Stable Tags
- **`v0.3-stable-no-flooding`** (commit b385e56, 2026-04-08) — no_drop fix + system stack
- **`v0.4-clean`** — Rust backend removed, Go backend only

### sing-box iOS Config
- **TUN stack**: `system` (единственный работающий для всех серверов)
- **Protocol**: VLESS Reality TCP + xtls-rprx-vision (порт 2096)
- **DNS**: FakeIP + DoH 1.1.1.1 via Auto
- **QUIC**: reject (UDP 443 блокируется, no_drop: true)
- **MTU**: 1400

### Что пробовали и не работает
| Подход | Результат | Почему |
|--------|-----------|--------|
| `stack: "mixed"` | Трафик не идёт | gVisor TCP + system UDP конфликтует с NetworkExtension |
| `stack: "gvisor"` | DE direct 4.2 Kbps | Чистый userspace ломает DE, NL работает 62 Mbps |
| Убрать QUIC reject | Медленнее | QUIC-over-TCP хуже чем HTTP/2-over-TCP |
| Random short_id | reality verification failed | Не в серверном списке допустимых |
| Reality keys в .env | Рассинхрон | 3 места хранения → ключи расходятся |

## Resolved Issues Log

### 2026-04-10: Cluster sync enabled and tested
- **Cluster mesh sync ENABLED** on DE+NL (was written, but disabled). Verified working: DE↔NL sync users+servers every 5 min + Redis pub/sub
- **CLUSTER_SECRET** added to docker-compose.yml env (was missing → container failed validation)
- **NL binary**: removed `chameleon-linux` from rsync exclude → NL now gets fresh binary each deploy (was using stale Docker cache)
- **Watchdog**: fixed `sudo test` for `/var/lib/docker/volumes/` (ubuntu can't read without sudo)
- **Alerts env**: `/etc/chameleon-alerts.env` chmod 644 (was 600 root-only → scripts couldn't read)
- **Telegram alerts**: tested and confirmed working — alert received on watchdog restart

### 2026-04-10: Infrastructure stabilization
- **Cluster auth**: shared secret (Bearer token) on all /api/cluster/* endpoints
- **Server mesh sync**: vpn_servers table synced via cluster pull/push + UpsertServerByKey
- **Telegram alerts**: watchdog + health-check.sh send alerts on singbox/chameleon failures
- **DB backups**: daily pg_dump at 3 AM, 7-day retention, alert on failure
- **sing-box extracted from docker-compose** → standalone container. Compose can't kill it.
- **Reality keys moved to DB** — single source of truth, no more .env key sync issues
- **Deploy script rewritten** — `./deploy.sh <node> [--with-singbox]`, post-deploy health checks
- **Watchdog + alerts** — auto-restart singbox + Telegram notification on restart/failure
- **short_id fix**: random short_ids → empty string (always valid)
- **NL keys regenerated**: old pair invalid → regenerated on NL directly

### 2026-04-09: User API + Admin improvements
- **sing-box fork deployed** (`sing-box-fork:v1.13.6-userapi`) on DE + NL
- **User API**: REST API on :15380 for add/remove/list users without restart
- **UserAPIClient** in chameleon backend — API first, SIGHUP fallback
- **Nodes metrics**: CPU/RAM/Disk/traffic/speed/connections
- **SPB Relay**: metrics-agent, nginx stream verified
- **Shield**: all VPN routes with priorities
- **Deploy**: singbox decoupled from chameleon, --no-deps
- **Project cleanup**: ~339 MB removed

### 2026-04-09: Multi-node architecture + Rust cleanup
- Cluster sync, server CRUD, per-server Reality keys
- Universal deploy.sh, config.production.yaml template
- Rust backend deleted (104 files, 8.5GB)

### 2026-04-09: DNS loop fix + SNI change
- Missing `{"action":"sniff"}` → DNS loop. Fixed.
- ads.x5.ru → ads.adfox.ru (40% timeout fix)

## Diagnostic Cheatsheet
```bash
# SSH
ssh ubuntu@162.19.242.30   # DE
ssh root@194.135.38.90     # NL

# Check singbox
docker ps | grep singbox
docker logs singbox --tail 20

# Check chameleon health
curl http://localhost:8000/health

# Check User API
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:15380/api/v1/inbounds/vless-reality-tcp/users

# Check VPN port
ss -tlnp | grep 2096

# Restart singbox (standalone)
cd ~/chameleon/backend-go && ./scripts/singbox-run.sh --force

# Watch watchdog logs
tail -f /var/log/singbox-watchdog.log

# iOS debug: ladybug icon → copy button → paste to Claude
```
