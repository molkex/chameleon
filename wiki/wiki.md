# Chameleon Wiki Summary (for Claude context)

## Current Architecture (2026-04-08)

### Traffic Flow
```
iPhone (libbox 1.13.5)
  ├─ Proxy selector (user picks server)
  │   ├─ 🇩🇪 Germany      : 162.19.242.30:2096 (sing-box server)
  │   └─ Auto (urltest, 3m interval, 100ms tolerance)
  │
  ├─ Route rules: sniff → hijack-dns → clash-direct → QUIC reject → ip_is_private
  ├─ DNS: DoH 1.1.1.1 (remote), DoH 8.8.8.8 (direct) — no detour in 1.13
  └─ Protocol: VLESS Reality TCP, sing-box server 1.13.6, SNI: ads.adfox.ru
```

### Servers
| Server | IP | VPN Port | VPN Engine | SSH |
|---|---|---|---|---|
| DE | 162.19.242.30 | 2096 | sing-box 1.13.6 | ubuntu + ChameleonDE2026Secure |
| NL | 194.135.38.90 | 2096 | sing-box 1.13.6 | root (key auth) |
| SPB Relay | 185.218.0.43 | — (nginx stream) | — | — |

### Critical Rules
1. **Both nodes**: sing-box 1.13.6 on DE + NL. Cluster sync enabled (HTTP reconciliation every 5m)
2. **SNI**: ads.adfox.ru (DE + relay-de), rutube.ru (NL + relay-nl) — never use google.com/cloudflare.com. ads.x5.ru deprecated (40% timeout). vk.com incompatible with REALITY (works locally but fails from external clients)
3. **sing-box route rules ORDER**: `{"action":"sniff"}` MUST be first, then `{"protocol":"dns","action":"hijack-dns"}`. Without sniff → DNS loop (packets go through VLESS to TUN address 172.19.0.2:53)
4. **DNS detour**: NOT needed in sing-box 1.13 — DNS servers go directly by default. `detour:"direct"` on empty direct outbound = error "makes no sense"
5. **DNS**: dns_remote=1.1.1.1 (DoH), dns_direct=8.8.8.8 (DoH), default_domain_resolver → dns-direct with ipv4_only

### iOS Server Selection
- `selectServer()` modifies selector `default` in config JSON, saves to UserDefaults, disconnect → poll until disconnected → reconnect
- Auto button calls `selectServer(groupTag: "Proxy", serverTag: "Auto")`
- Config sources: 1) tunnel options (manual connect), 2) UserDefaults (on-demand), 3) file (fallback)

## Stable Tags
- **`v0.3-stable-no-flooding`** (commit b385e56, 2026-04-08) — текущий стабильный. no_drop fix + system stack, MUX outbounds убраны из конфига.
- **`v0.4-clean`** — следующий тег после cleanup (удаление MUX кода из Rust, обновление sing-box сервера до 1.13.6).

## Stable Baseline: `v0.1-stable-system-stack` (commit 6f584b6, 2026-04-08)

### Что работает
| Сервер | Скорость | Статус |
|--------|----------|--------|
| 🇩🇪 Germany direct | 48 Mbps | ✅ |
| 🇳🇱 Netherlands direct | 62 Mbps | ✅ |
| 🇷🇺 Russia → DE (relay) | 50 Mbps | ✅ |
| 🇷🇺 Russia → NL (relay) | ~50 Mbps | ✅ |

### Конфигурация sing-box (iOS)
- **TUN stack**: `system` (единственный работающий для всех серверов)
- **Protocol**: VLESS Reality TCP + xtls-rprx-vision (порт 2096)
- **DNS**: FakeIP + DoH 1.1.1.1 via Auto
- **QUIC**: reject (UDP 443 блокируется, браузеры используют TCP/H2)
- **MTU**: 1400
- **Log level**: info
- **config_version**: timestamp в JSON (убирается ConfigSanitizer перед sing-box)

### Известные проблемы (RESOLVED)
1. ~~**Flooding** (`dropped due to flooding`)~~ — **РЕШЕНО** в v0.3: `no_drop: true` на QUIC reject правиле. Причина: sing-box после 50 reject'ов/30с переключался с ICMP→drop, браузер ждал QUIC таймаут. `no_drop` гарантирует мгновенный ICMP ответ всегда.
2. **QUIC fallback задержка** — браузер пытает QUIC → reject → fallback на TCP. На iOS TUN ICMP может не доходить до приложения, поэтому fallback ~3-5с. Если убрать reject — весь трафик идёт QUIC-over-TCP, что ещё медленнее.
3. **DE urltest EOF** — иногда urltest для DE показывает EOF, но реальный трафик работает.

### Что пробовали и не работает
| Подход | Результат | Почему |
|--------|-----------|--------|
| `stack: "mixed"` | Трафик не идёт | gVisor TCP + system UDP конфликтует с NetworkExtension |
| `stack: "gvisor"` | DE direct 4.2 Kbps | Чистый userspace ломает DE, NL работает 62 Mbps |
| Убрать QUIC reject | Медленнее | QUIC-over-TCP хуже чем HTTP/2-over-TCP |
| `reject method: "port_unreachable"` | VPN не стартует | Невалидное значение в sing-box 1.13 |
| `log: "debug"` | VPN не стартует или OOM | Extension убивается системой из-за объёма логов |

### Следующие шаги
1. ~~**Деплой NL**~~ ✓ Go backend + sing-box 1.13.6 на NL (194.135.38.90)
2. ~~**Кластер**~~ ✓ cluster sync работает DE ↔ NL (users синхронизированы)
3. **Relay** — протестировать SPB relay (relay-de :443, relay-nl :2098)
4. **Admin panel** — добавить поле reality_public_key в UI серверов
5. **Nginx на NL** — собрать admin SPA (сейчас нет nginx, только API)

## Resolved Issues Log

### 2026-04-09: Multi-node architecture + Rust cleanup
- **Cluster sync wired up**: `cluster.Syncer` now created and started in main.go (was implemented but never called)
- **Cluster routes registered**: `/api/cluster/pull` and `/api/cluster/push` endpoints active when cluster enabled
- **Server CRUD**: Admin API now supports POST/PUT/DELETE `/api/admin/servers` (frontend already had UI)
- **Per-server Reality keys**: Added `reality_public_key` column to `vpn_servers` table. Client config uses per-server key with fallback to engine default. Critical for multi-node (each node has own key pair)
- **CORS configurable**: Moved from hardcoded to `server.cors_origins` in config.yaml
- **Universal deploy.sh**: Accepts target arg (`./deploy.sh de`, `./deploy.sh nl`), node registry in script, per-node Reality keys support
- **config.production.yaml**: Now a generic template, node-specific values injected by deploy.sh
- **Rust backend deleted**: Entire `backend/` directory (104 files, 8.5GB), old infrastructure files, root docker-compose.yml, PLAN.md
- **Migration seeds**: NL SNI changed from `vk.com` to `ads.adfox.ru` (vk.com incompatible with REALITY)

### 2026-04-09: DNS loop fix + SNI change (Go backend)
- **DNS loop** (VPN connected, no sites load): Missing `{"action":"sniff"}` route rule. In sing-box 1.13, sniff moved from inbound to route action. Without it, `protocol:"dns"` never matches → hijack-dns doesn't intercept → DNS packets go through VLESS to 172.19.0.2:53 (TUN address) → infinite loop.
- **SNI change**: ads.x5.ru → ads.adfox.ru. ads.x5.ru was timing out 40% from DE server. vk.com tested but incompatible with REALITY from external clients (works localhost only). ads.adfox.ru: 100% stable, ~174ms, Yandex ad platform.
- **Route rules** now match working Rust config: sniff → hijack-dns → clash direct → QUIC reject (udp:443, no_drop:true) → ip_is_private→direct
- **detour:"direct"** removed from dns-direct: sing-box 1.13 DNS servers go directly by default; detour to empty direct outbound = error
- **UI**: Added version + config hash to main screen footer for debugging

### 2026-04-08: Cleanup + sing-box server update (session 3)
- **MTProxy**: проверено — отсутствует на DE сервере, ничего удалять не нужно
- **Порт 2095 (MUX inbound)**: уже убран из Xray конфига ранее
- **MUX код в Rust**: удалён из `vless_reality.rs` (tcp-mux ветка, порт 2094 hardcode, multiplex конфиг)
- **sing-box сервер**: обновлён до v1.13.6 в docker-compose
- **singbox.rs**: уже был очищен от MUX outbounds в коммите b385e56
- **Стабильный тег**: v0.3-stable-no-flooding (b385e56) остаётся текущим; после cleanup будет v0.4-clean

### 2026-04-08: Flooding + DE performance (session 2)
- **Flooding**: `system` stack → `dropped due to flooding` при speedtest. `gvisor` убирает flooding но ломает DE. Решение: оставить `system`, планировать переход на XHTTP+mux.
- **DE DIRECT outbound без UseIPv4**: engine.rs генерировал DIRECT без domainStrategy → Xray использовал IPv6 (сломано на OVH) → EOF. Фикс в commit 92bdd9e.
- **config_version**: добавлен timestamp в JSON конфиг + отображение в debug report. ConfigSanitizer убирает перед sing-box.
- **Appium**: настроен для remote control iPhone. Team ID: 99W3C374T2, WDA bundle: com.chameleonvpn.wda.

### 2026-04-08: DE direct не грузит (commit 0290013)
- **Cause 1**: Xray freedom outbound used IPv6 (broken on OVH) → `domainStrategy: UseIPv4`
- **Cause 2**: Xray in Docker bridge (172.18.0.3) → switched to `network_mode: host`
- **Cause 3**: iOS Auto button didn't reconnect → now calls `selectServer()`

### 2026-04-07: DNS slow 9-14s (commit beee3ff)
- DNS detour hardcoded to "Proxy" selector → changed to "Auto" urltest

### 2026-04-07: Connection drops (commit 4f7a2a3)
- JWT token expiry not handled → auto-refresh + re-register
- Fixed WiFi/LTE handover, Docker volumes for config persistence

## Diagnostic Cheatsheet
```bash
# SSH to DE
sshpass -p "ChameleonDE2026Secure" ssh ubuntu@162.19.242.30

# Check xray health
sudo docker inspect xray --format='NetworkMode: {{.HostConfig.NetworkMode}}'  # must be: host
sudo docker logs xray --since 2m 2>&1 | grep -v api | tail -10

# Test outbound
curl -4 -sk --max-time 5 -w "HTTP:%{http_code} TIME:%{time_total}s\n" -o /dev/null https://www.gstatic.com/generate_204

# iOS debug: ladybug icon → copy button → paste to Claude
```
