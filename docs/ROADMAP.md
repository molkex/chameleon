# ROADMAP — MadFrog VPN / Chameleon Core

> 🤖 Mirror: [agent-readable YAML](roadmap.yaml) — keep in sync. Edit either, sync the other.

> Единый источник правды для планов. Все новые задачи — сюда. Не плодим `*_plan.md` по углам.
> Обновлено: 2026-04-23

## Now (в работе / блокеры)

### iOS / UX
- **iOS P1 (followup):** Локализация — 14 строк сделано (api/subscription errors + country names). Остаются: `StringUtils.pluralDays/Servers` (нужен Stringsdict с CLDR plurals для en/ru parity); ServerGroup ILIKE matchers НЕ user-facing, оставить.

### Backend / API
- **GO P0 (BE-01):** Apple StoreKit Server API v2 верификация подписок — сейчас доверяем клиентскому `transaction_id`. Требует ASC API key + JWT signing. Отдельная сессия с креденшелс.
- **GO P0:** MSK API relay (217.198.5.52) — задеплоен, но не подключён в `AppConfig.baseURL`. Решить: подключать или удалить (см. Decisions deferred)
- **GO MEDIUM (BE-10):** Provider passwords plaintext в БД — нужна схема encryption-at-rest (KEK в env, политика ротации DEK). Отдельный design.

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
- **iOS:** RoutingMode picker — заменить `.menu` на 3 selectable cards inline
- **iOS:** Session duration — стандартизировать между Calm и Neon темами (TimerView только в Neon)
- **iOS:** Settings → About — кнопка `mailto:support@madfrog.online`
- **iOS:** Account username — для `u_*` показывать «Anonymous (trial)», для Apple Sign-In показывать email
- **iOS:** `DebugLogsView` — `#if DEBUG`, содержит хардкод IP + UUID
- **iOS:** Эмодзи лягушка в UI → векторный SVG логотип

### Security — iOS
- **MEDIUM:** libbox debug mode (`ExtensionProvider:153`) — выключить в Release
- **MEDIUM:** Payment URL whitelist — `freekassa.ru` / `pay.freekassa.ru` перед открытием в Safari
- **MEDIUM:** Diagnostics секция — Face ID / Touch ID gate перед debug logs
- **MEDIUM (followup):** TLS cert pinning — InsecureDelegate теперь scoped к whitelist хостов, но полное pinning требует чтобы backend публиковал serving cert fingerprint (например `/api/v1/server/info`).

### Backend / Go
- **MEDIUM:** v2ray_api stats per-user — новые users (добавленные через user-api без full reconfig) не появляются в `experimental.v2ray_api.stats.users`, их трафик не считается. Требует периодического check-and-reconfig от traffic collector ИЛИ изменений в sing-box чтобы поддерживать динамические stats users. Не quick-fix.

### iOS — bugs (medium)
- **iOS-11:** Race в `ConfigStore` миграции (Keychain write во время read) — actor/lock
- **iOS-12:** Errors silently ignored (`try?`) в VPNManager / ExtensionPlatformInterface — логировать через `os.log`
- **iOS-13:** Нет `timeoutIntervalForResource` в URLSession — добавить cap на total response time
- **iOS-14:** `tunnel?.reasserting` читается не с main thread (`ExtensionPlatformInterface:262`) — диспатч на main
- **iOS-15:** Debug log file I/O на main thread (`AppShellView:69-70`) — async Task
- **iOS-16:** API error strings хардкод RU — `Localizable.strings`
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
- ✓ Phase 0-2 bugfixes (security, iOS crashes, backend auth) — `docs/archive/2026-04/bugfix-plan.md`
- ✓ `infrastructure/topology.yaml` как single source of truth для инфры (2026-04-23)
- ✓ Wiki cleanup — архив старых аналитик/UI прототипов в `docs/archive/2026-04/` (2026-04-23)
- ✓ **Структурный рефакторинг (2026-04-23):** `backend-go/` → `backend/`, `apple/` → `clients/apple/`, `admin/` → `clients/admin/`, `wiki/` → `docs/`, `wiki.md` → `OPERATIONS.md`, корневые скрипты → `infrastructure/deploy/`, `ChameleonVPN/` → `MadFrogVPN/`, `ChameleonMac/` → `MadFrogVPNMac/`. Target+scheme переименованы, xcodeproj регенерирован.
- ✓ **YAML mirrors для агентов (2026-04-23):** `README.yaml` + `docs/{operations,troubleshooting,roadmap,architecture,payments}.yaml`.
- ✓ **Testing foundation (2026-04-23):** GitHub Actions `backend.yml` + `admin.yml` + `ios.yml`; `backend/tests/{integration,e2e}/` skeleton.
- ✓ **iOS P0 (2026-04-23, `07a1afb`):** /config 404 → re-register, pill реактивный через @Observable, refresh button фетчит конфиг.
- ✓ **iOS security HIGH (2026-04-23, `378f984`):** debug sanitized-config `#if DEBUG`, Keychain `ThisDeviceOnly`, `NSAllowsArbitraryLoads` → `NSExceptionDomains`, InsecureDelegate scoped к whitelist хостов.
- ✓ **Backend MEDIUM (2026-04-23, `bdf5dd4`):** rate-limiter goroutine leak (ctx-aware cleanup), `cluster.{Syncer,Subscriber}.Stop()` идемпотентен, SearchUsers `maxSearchLen=100`.
- ✓ **iOS quick wins (2026-04-23, `ee5dae7`):** dead code `hasDnsOutbound`, ServerListView one-shot probe, error toast auto-dismiss + close button + VoiceOver label.
- ✓ **iOS i18n pass 1 (2026-04-23, `4d7f3e1`):** 14 хардкод-RU вынесены в Localizable.strings (en+ru) — APIClient errors (5), SubscriptionManager IAP errors (4), ServerGroup country names (5).
- ✓ **Backend MEDIUM verification (2026-04-23):** обнаружено что `init.sql` seed (зафиксировано раньше), `UpsertServerByKey` COALESCE-NULLIF (зафиксировано раньше), `FindLocalServer` startup check (`main.go:201-203` возвращает error если `realityPrivateKey == ""`) — все три уже сделаны, ROADMAP устаревал.
- ✓ **iOS P1 verification (2026-04-23):** Apple Sign-In fallback (`OnboardingView.swift:274-287` `guestButton` → `signInAnonymous()`), Paywall routing (`PaywallRouter.swift` использует Storefront + Locale.region для CIS), VPN permission primer (`MainView.swift:100-106` sheet) — все три уже сделаны.

---

## Sources scanned
- `docs/bugfix-plan.md`, `docs/CLEANUP_CANDIDATES.md`, `docs/IOS_UX_REVIEW.md`, `docs/TROUBLESHOOTING.md`
- `docs/CODEX_AUDIT_APPLE_SECURITY.md`, `_RUNTIME.md`, `_CHAIN_SECURITY.md`, `_INFRA_FINDINGS.md`
- `docs/OPERATIONS.md`, `infrastructure/topology.yaml` (inconsistencies + unknown_fields)
- Memory: `project_chameleon_cleanup_needed.md`, `project_vpn_tunnel_broken.md`, `project_ios_network_race.md`, `project_ru_api_relay.md`
- Grep TODO/FIXME в `clients/apple/`, `backend/`, `clients/admin/` — code-level чистый

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
