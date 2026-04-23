# ROADMAP — MadFrog VPN / Chameleon Core

> Единый источник правды для планов. Все новые задачи — сюда. Не плодим `*_plan.md` по углам.
> Обновлено: 2026-04-23

## Now (в работе / блокеры)

### iOS / UX
- **iOS P0:** `/api/v1/mobile/config` 404 на свежей установке build 26 — нужны логи backend от живого устройства
- **iOS P0:** Pill на главной не обновляется при выборе сервера — `configStore.selectedServerTag` не триггерит `@Observable AppState`
- **iOS P0:** Кнопка ↻ в `ServerListView` зовёт `urlTest()`, должна `refreshConfig()` — юзер не может форс-обновить старый кэш
- **iOS P1:** Apple Sign-In fallback — кнопка «продолжить анонимно», задействовать `autoRegister()` (endpoint есть, не проводен в UI)
- **iOS P1:** Paywall routing — `Locale.current.region == "RU"` → `WebPaywallView`, иначе `PaywallView` (StoreKit 2 обязателен для не-RU App Store)
- **iOS P1:** Локализация — 28 хардкод-RU строк (`WebPaywallView`, `MenuBarContent`, server group labels) → `Localizable.strings`
- **iOS P1:** VPN permission priming — экран между Sign-In и первым connect объясняющий «iOS попросит разрешение на VPN-профиль»

### Backend / API
- **GO P0 (BE-01):** Apple StoreKit Server API v2 верификация подписок — сейчас доверяем клиентскому `transaction_id`
- **GO P0:** MSK API relay (217.198.5.52) — задеплоен, но не подключён в `AppConfig.baseURL`. Решить: подключать или удалить (см. Decisions deferred)

### Infrastructure / VPN
- **Infra HIGH:** Packet loss DE→RU mobile на TCP VLESS — Hysteria2 (UDP:443) и TUIC (UDP:8443) задеплоены как обход, нужен реальный замер
- **Infra HIGH:** SPB Relay (185.218.0.43) — нет :80 HTTP-fallback маппинга
- **Infra HIGH:** Log rotation на DE+NL — `/var/log/chameleon-*.log` без ротации, растут безгранично

---

## Next (1-2 недели)

### iOS — bugs / UX (P1+)
- **iOS:** Hardcoded build hash в `MainViewCalm:49-51` — спрятать за `#if DEBUG` или long-press на версии в Settings
- **iOS:** `MainView` — 4 sheet'а без ID, могут пропускать быстрые тапы → один `sheet(item:)` с enum `ActiveSheet`
- **iOS:** Hero card в disconnected — слишком тёмный (Calm theme), брайтер accent
- **iOS:** Бесконечный ping polling в `ServerListView` (MainView:256-263) — убрать `while !Task.isCancelled`, оставить one-shot + manual refresh
- **iOS:** RoutingMode picker — заменить `.menu` на 3 selectable cards inline
- **iOS:** Session duration — стандартизировать между Calm и Neon темами (TimerView только в Neon)
- **iOS:** Settings → About — кнопка `mailto:support@madfrog.online`
- **iOS:** Error toast — auto-dismiss 5s + явный X (сейчас sticky)
- **iOS:** Error toast — VoiceOver label + announcement on appear
- **iOS:** Logout — алерт-подтверждение (как в `deleteAccount`)
- **iOS:** Account username — для `u_*` показывать «Anonymous (trial)», для Apple Sign-In показывать email
- **iOS:** `DebugLogsView` — `#if DEBUG`, содержит хардкод IP + UUID
- **iOS:** Эмодзи лягушка в UI → векторный SVG логотип

### Security — iOS
- **HIGH:** `InsecureDelegate` TLS bypass на fallback (`APIClient:76-86`) — pinned cert или валидация
- **HIGH:** `NSAllowsArbitraryLoads` глобально (Info.plist) — заменить на domain-specific exceptions
- **HIGH:** Debug `sanitized-config.json` в production extension (`ExtensionProvider:200`) — `#if DEBUG`
- **MEDIUM:** Keychain accessibility — `kSecAttrAccessibleAfterFirstUnlock` → `AfterFirstUnlockThisDeviceOnly`
- **MEDIUM:** libbox debug mode (`ExtensionProvider:153`) — выключить в Release
- **MEDIUM:** Payment URL whitelist — `freekassa.ru` / `pay.freekassa.ru` перед открытием в Safari
- **MEDIUM:** Diagnostics секция — Face ID / Touch ID gate перед debug logs

### Backend / Go
- **MEDIUM (BE-08):** Goroutine leak в rate limiter cleanup (`ratelimit.go:33,75`) — добавить ctx/stopCh
- **MEDIUM (BE-09):** `Stop()` не идемпотентен (`cluster/sync.go:130`, `pubsub.go:147`) — `sync.Once` для `close(stopCh)`
- **MEDIUM (BE-10):** Provider passwords в plaintext в БД — шифровать
- **MEDIUM (BE-11):** `SearchUsers` без длины — лимит 100 символов на pattern
- **MEDIUM:** `migrations/init.sql` seed конфликтует с ALTER TABLE — либо убрать seed, либо merge ALTER в init
- **MEDIUM:** `UpsertServerByKey` небезопасен из пустых полей — `COALESCE(NULLIF(EXCLUDED.x, ''), vpn_servers.x)`
- **MEDIUM:** Startup check — если `FindLocalServer.reality_private_key` пустой, не стартовать вместо silent fallback
- **MEDIUM:** v2ray_api stats per-user — авто-регистрация новых users в `experimental.v2ray_api.stats.users` (сейчас только при full reconfig)

### iOS — bugs (medium)
- **iOS-11:** Race в `ConfigStore` миграции (Keychain write во время read) — actor/lock
- **iOS-12:** Errors silently ignored (`try?`) в VPNManager / ExtensionPlatformInterface — логировать через `os.log`
- **iOS-13:** Нет `timeoutIntervalForResource` в URLSession — добавить cap на total response time
- **iOS-14:** `tunnel?.reasserting` читается не с main thread (`ExtensionPlatformInterface:262`) — диспатч на main
- **iOS-15:** Debug log file I/O на main thread (`AppShellView:69-70`) — async Task
- **iOS-16:** API error strings хардкод RU — `Localizable.strings`
- **iOS-17:** Dead code `hasDnsOutbound` (AppState:89,95) — удалить
- **iOS-18:** `sharedDefaults` может быть nil без warning — лог если App Group не настроен

### Infrastructure / Ops
- **SRV-07:** Docker cleanup — `docker system prune -a --volumes` на DE (~27GB), NL (~5GB)
- **SRV-09:** SSL cert DE истекает 2026-05-21 — Cloudflare auto-renewal или Let's Encrypt на origin
- **SRV-10:** SPB Relay — rate-limit для broken REALITY handshakes (60s connects), recheck :2098 relay config
- **SRV-11:** NL RAM — 1.9GB, 34% used, swap 57MB — мониторить, апгрейд если swap > 100MB
- **SRV-12:** File descriptor limit 1024 на NL — `/etc/security/limits.conf` + docker daemon
- **SRV-13:** SSL Cloudflare ↔ DE — проверить mode = «Full», не «Flexible»

### Admin SPA
- **ADM-05:** Cookie missing `SameSite=Strict`
- **ADM-06:** Form validation отсутствует (JSON, URL, numeric)

---

## Later (бэклог)

### Features (стандарт VPN индустрии)
- **Kill switch UI toggle** — `NEOnDemandRule` уже есть, выставить в Settings (medium)
- **Auto-connect на untrusted WiFi** — детект SSID, тост-предложение (medium)
- **Auto-connect on launch** — UserDefault flag + `toggleVPN()` в init (low)
- **Custom DNS per-app** — sing-box rules уже поддерживают, выставить в Settings (medium)
- **Live traffic stats** — Clash API уже трекает, отрисовать в main UI (medium)
- **Tunnel drop notifications** — `UNUserNotificationCenter` (medium)
- **Lock Screen widget** — WidgetKit + App Group shared state (medium-high, iOS 17+)
- **Live Activity / Dynamic Island** — ActivityKit статус VPN (medium-high)
- **Shortcuts / Siri** — AppIntents для Connect/Disconnect/Switch Server (low)
- **iCloud sync settings** — `NSUbiquitousKeyValueStore` для theme/server/routing (low-medium)
- **Family Sharing unlock** — `product.isFamilyShareable = true` (low, StoreKit only)
- **Multi-hop visibility** — UI показывает «Russia → DE relay» (low)

### Refactoring / Code quality
- **iOS:** `MainViewCalm` + `MainViewNeon` дублирование 90% — extract shared ViewModel + theme renderers (medium)
- **iOS:** Dynamic Type — `font(.system(size:))` → семантические `.title3`, `.headline` (low, важно для accessibility)
- **iOS:** Light mode — варианты Calm/Neon ИЛИ явный `.preferredColorScheme(.dark)` (low-medium)
- **iOS:** iPad Pro layout — `ViewThatFits` или split-view, hero card сейчас тянется на 1000pt (medium)
- **iOS:** Accessibility — VoiceOver test, labels на все интерактивные (low-medium, ongoing)
- **GO:** Server error responses → generic messages в admin UI (убрать stack traces из юзер-toast'ов)
- **GO:** Pagination/sorting на `/users` endpoint
- **GO:** Per-server status endpoint (cpu/ram/users/traffic)

### Documentation / Knowledge
- **Wiki:** README.md — убрать legacy IP (85.239.49.28, 194.135.38.90, 89.169.144.42), обновить infra
- **Wiki:** TROUBLESHOOTING — секция «что делать если VLESS DE не работает» (Hysteria2/TUIC fallback)

---

## Decisions deferred (требует обсуждения)

- **Architecture simplification** — выкинуть relay вообще? Оставить только direct DE/NL? Сейчас relay-de + relay-nl — 2 из 6 в Auto urltest. Решение зависит от профиля юзеров (RU-blocked vs остальные).
- **MSK relay actual wiring** — `AppConfig.baseURL` → `api.madfrog.online` (217.198.5.52) или Cloudflare + direct IP fallbacks? Зависит от замера: помогает ли MSK relay RU-mobile или direct IPs достаточно быстры.
- **NL как primary relay target** — relay-nl сейчас `SPB:2098 → NL:2096`. Стоит ли наоборот сделать NL основным relay-target?
- **QUIC :443 UDP** — Hysteria2 на :443 UDP конфликтует с обычным HTTPS. Перенести H2 на :8443, TUIC на другое? Сейчас работает, ревизия по жалобам.
- **Per-server Reality flow field** — план тестить `flow: "8443 no-flow"` для TUIC сервера, но H2/TUIC уже UDP — вероятно не нужно.

---

## Done

### 2026-04
- ✓ SPB relay mapping fixed (de+nl targets updated)
- ✓ Hysteria2 UDP:443 deployed на DE
- ✓ TUIC v5 UDP:8443 deployed на DE
- ✓ MTU 1400 → 1280 для iOS
- ✓ Mux removed из VLESS Reality (incompatible с vision flow)
- ✓ libbox/sing-box debug-mode в ExtensionProvider
- ✓ v2ray_api gRPC stats на DE+NL (per-user traffic persistence)
- ✓ iOS preflight probe hardening (fast-fail на bad servers)
- ✓ MSK API relay infrastructure (217.198.5.52 nginx, не подключён в iOS)
- ✓ Cluster sync на DE+NL (Redis pub/sub + HTTP reconciliation)
- ✓ Phase 0-2 bugfixes (security, iOS crashes, backend auth) — `wiki/archive/2026-04/bugfix-plan.md`
- ✓ `infrastructure/topology.yaml` как single source of truth для инфры (2026-04-23)
- ✓ Wiki cleanup — архив старых аналитик/UI прототипов в `wiki/archive/2026-04/` (2026-04-23)

---

## Sources scanned
- `wiki/bugfix-plan.md`, `wiki/CLEANUP_CANDIDATES.md`, `wiki/IOS_UX_REVIEW.md`, `wiki/TROUBLESHOOTING.md`
- `wiki/CODEX_AUDIT_APPLE_SECURITY.md`, `_RUNTIME.md`, `_CHAIN_SECURITY.md`, `_INFRA_FINDINGS.md`
- `wiki/wiki.md`, `infrastructure/topology.yaml` (inconsistencies + unknown_fields)
- Memory: `project_chameleon_cleanup_needed.md`, `project_vpn_tunnel_broken.md`, `project_ios_network_race.md`, `project_ru_api_relay.md`
- Grep TODO/FIXME в `apple/`, `backend/`, `admin/` — code-level чистый

---

## Stats

- **Total tasks:** ~85 (Now: 7, Next: 40, Later: 30, Deferred: 5, Done: 13)
- **Top categories:** iOS UX/Localization (15), Security (9), Backend/GO (9), Infra/Ops (8), Features (12)

**Блокеры для App Store submission:**
1. Apple Sign-In fallback (P0 onboarding)
2. Paywall routing (не-RU = StoreKit, не WebPaywall)
3. Hard-coded RU в UI + DebugLogsView в production
4. Apple subscription verification (BE-01)

**Security must-do до public launch:**
- TLS validation (InsecureDelegate)
- Debug config files из production
- Keychain accessibility downgrade
- Diagnostics auth-gating
