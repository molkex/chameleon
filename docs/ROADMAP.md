# ROADMAP — MadFrog VPN / Chameleon Core

> 🤖 Mirror: [agent-readable YAML](roadmap.yaml) — keep in sync. Edit either, sync the other.

> Единый источник правды для планов. Все новые задачи — сюда. Не плодим `*_plan.md` по углам.
> Обновлено: 2026-04-23

## Now (в работе / блокеры)

### 🚀 Launch Checklist v1.0 (2026-04-24)

> Competitive gap-анализ vs Karing / Happ Plus (оба sing-box-based). Наш engine не уступает — пробелы в iOS-специфичных фичах и полировке. Детали анализа — внизу ROADMAP секция "Launch analysis".

#### P0 — блокеры App Review / retention (нельзя релизиться)
- **LAUNCH-01:** `PrivacyInfo.xcprivacy` — обязательно Apple с мая 2024. Декларировать UserDefaults usage, DeviceName usage, SystemBootTime usage. Без файла — авто-reject.
- **LAUNCH-02:** Family Sharing для subscription — ASC флаг. Без него App Review задаёт вопросы по 3.1.2.
- **LAUNCH-03:** Crash reporting (`TelemetryDeck` privacy-friendly или Sentry). Без него слепая зона на 5%+ крашей в проде.
- **LAUNCH-04:** Widget (Home / Lock Screen) — минимум 1 штука: "connect toggle". iOS 16+ юзеры ожидают кнопку VPN на главном экране.
- **LAUNCH-05:** Control Center Widget (iOS 18 `ControlWidget`) — кнопка управления VPN в Control Center / Action Button / Lock Screen. Happ Plus умеет. Без этого приложение выглядит устаревшим.
- **LAUNCH-06:** Shortcuts App integration — минимум 3 actions: connect, disconnect, switch server. Через `AppIntent` (iOS 16+). Юзеры делают автоматизации ("подключиться при открытии Instagram" и т.п.).
- **LAUNCH-07:** Auto-connect on untrusted WiFi — `NEOnDemandRule` с `SSIDMatch` / `InterfaceTypeMatch: .cellular`. Стандарт индустрии. Без этого юзер платит но включает руками каждый раз.
- **LAUNCH-08:** Disconnect notification (`UNUserNotificationCenter` + `NEVPNStatus`-observer). Чтобы юзер узнавал когда разорвался тоннель, а не думал "работает".

#### P1 — сильно повысит качество восприятия
- **LAUNCH-09:** Live traffic sparkline на главном экране — up/down за последние 5 минут. Не сложно, большая UX-разница.
- **LAUNCH-10:** Live Activity / Dynamic Island (iOS 16.1+) — пока VPN подключён, DI показывает up/down speed. Wow-фактор, Happ Plus имеет.
- **LAUNCH-11:** Ручной ping per-server в picker'е серверов. Сейчас auto-urltest работает скрыто — юзер не понимает почему выбран Auto = ??. Кнопка "Обновить пинги" + indicator рядом с каждым флагом.
- **LAUNCH-12:** uTLS fingerprint rotation — сейчас `chrome` статично в `clientconfig.go:60`. Варьировать между `chrome`/`firefox`/`safari`/`random` по серверам или per-user. Защита от DPI fingerprinting.
- **LAUNCH-13:** DoQ (DNS-over-QUIC) вместо DoH — sing-box 1.13 поддерживает, просто смена `type` в `clientDNSServer`. Быстрее, меньше DPI-сигнатура.
- **LAUNCH-14:** Accessibility pass — VoiceOver labels на всех интерактивных элементах. App Review может спросить.

#### P2 — можно после запуска
- Кастомный DNS в настройках (override `dns-remote` / `dns-direct`)
- Кастомные rule-set URL
- Apple Watch companion app
- Больше локализаций (ES/TR/AR — крупные VPN рынки)
- Export нашего конфига как sing-box URL (для паверюзеров)
- Win-back offer для churned subscription

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
- **Infra P0 (2026-04-24):** Новая VPN-нода off-OVH — DE (OVH Frankfurt, `162.19.242.30`) заблокирован на уровне ASN у RU мобильных операторов (MTS/Beeline/MegaFon/T2). VLESS/H2/TUIC все падают на RU LTE, работают только на WiFi. Замена/дополнение к DE-exit. Детали ниже.

#### P0: новая нода off-OVH (замена DE-exit)

**Проблема.** OVH AS16276 range (включая `162.19.242.30`) сбрасывается RU мобильными
операторами на TCP/UDP:443 → VLESS/Hysteria2/TUIC все мертвы на LTE. NL Timeweb
(`147.45.252.234`, AS9123) пока не в блок-листе. Build 30 уже имеет промежуточные
смягчения: NL primary в urltest (клиент 2026-04-24) + RU-aware race (клиент
2026-04-24, пропускает DE leg для `Locale.current.region == RU`).

**Кандидаты хостинга (не OVH, не Cloudflare-origin).**
1. **Hetzner Falkenstein (AS24940)** — дёшево (€4.5/мес CX22), AS не в публичных
   RU-блок-листах на 2026-04. Риск: Hetzner активно борется с abuse, потребуется
   whitelist VPN use-case. Проверка: `tcptraceroute 94.130.X.X 443` с MTS/Beeline.
2. **Hetzner Helsinki (AS24940, Finland)** — тот же AS, но гео ближе к RU,
   латенси с СЗФО ниже чем с Falkenstein.
3. **DigitalOcean Frankfurt (AS14061)** — дороже ($6), но другая AS. Исторически
   DO IP'шники попадают в блок-листы быстрее (много abuse).
4. **Vultr Frankfurt (AS20473)** — €6/мес, AS известна, но пока не в массовых
   RU-блок-листах.
5. **Contabo Nuremberg (AS51167)** — €5/мес, большой объём IP, но репутация у
   ряда RU-DPI низкая.

**Acceptance criteria (прежде чем ставить нод в prod selector).**
- [ ] `tcptraceroute <IP> 443` с RU-LTE (MTS / Beeline / MegaFon / T2) — SYN-ACK
  доходит, не DROP/RST на approach hop.
- [ ] `tcptraceroute <IP> 8443` (TUIC) — то же.
- [ ] VLESS Reality handshake с RU-LTE — успех в <2s на 5/5 попыток.
- [ ] sing-box client config: NL primary → новая нода secondary → DE last;
  отдельный тест `urltest` на LTE выбирает одну из работающих нод.
- [ ] backend `/health` с нового сервера отвечает <200ms от CF-MSK edge.
- [ ] cluster sync (vpn_users) стабилен 24h без `vpn_username conflict`-спама.

**План миграции.**
1. Поднять кандидата (Hetzner Helsinki как default) через
   `infrastructure/deploy/install.sh`.
2. Добавить в `vpn_servers` через admin API с `is_active=false, sort_order=50`.
3. Протестировать с 3 реальных RU-LTE-сим локально (не только speedtest).
4. Если ✅ по acceptance — `is_active=true, sort_order=15` (между NL=10 и DE=20).
5. Понаблюдать 48h. Если DE-exit стабильно проигрывает urltest — перевести
   DE на `sort_order=90` (оставить как резерв) или `is_active=false`.
6. Долгосрочно: retire DE-exit, оставить только backend-role (админка / API
   origin), но trafic-exit увести на Hetzner + SPB relay.

**Связанные фиксы (уже в коде, 2026-04-24).**
- `backend/internal/vpn/clientconfig.go:isNLServer` — stable-sort NL первым в
  Auto urltest outbounds.
- `clients/apple/MadFrogVPN/Models/APIClient.swift:dataWithFallback` — `isRURegion`
  фильтрует `162.19.242.30` из race-legs, экономит ~6s на RU-логине.
- Оба фикса landing-safe для не-RU: non-RU сохраняют прежнее поведение.

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
- **MEDIUM (нужно design-решение):** v2ray_api stats per-user — новые users (добавленные через user-api без full reconfig) не появляются в `experimental.v2ray_api.stats.users`, их трафик не считается. Trade-offs:
  - **Path A:** Периодический check-and-reload (раз в N часов). Минус: reload ломает активные VPN-сессии.
  - **Path B:** Reload после batch создания N юзеров. Минус: то же самое + сложнее логика.
  - **Path C:** Patch sing-box чтобы поддерживать динамические `stats.users` через User API. Большой scope, upstream PR.
  - **Path D (workaround):** Считать трафик через clash_api `/connections` per-IP вместо v2ray_api per-user. Требует переписать stats.go.
  - Рекомендуется: D как краткосрочное, C как долгосрочное.

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
- ✓ **iOS Settings UX + iOS-13/14/15/18 (2026-04-23, `95eb017`):** Contact support mailto, DebugLogsView `#if DEBUG`, `timeoutIntervalForResource=30`, `tunnel.reasserting` на main thread, file I/O off main, `sharedDefaults` nil warning.
- ✓ **BE-10 provider passwords AES-256-GCM (2026-04-23, `7101527`):** новый пакет `internal/secrets`, opt-in via `CHAMELEON_PROVIDERS_ENCRYPTION_KEY`, lazy migration, 6 unit tests.

### 2026-04-24 (overnight pass)
- ✓ **Cluster sync noise reduction (`e8449af`):** `idx_users_vpn_username` 23505 errors на DE+NL — добавлен `cluster/errors.go isDuplicateVPNUsername`, demote error→warn (vpn_username deterministic on device_id, collision after re-register expected). Real failures сохраняют error level.
- ✓ **Security CRITICAL (`e8449af`):**
  - Admin cookie `Secure=isHTTPS(c)` через `X-Forwarded-Proto`, SameSite Lax → Strict.
  - `cmd/metrics-agent`: новые флаги `-bind` (default 127.0.0.1) + `-auth-token` (env `METRICS_AGENT_TOKEN`); fail to start если public bind без token.
  - `admin/routes.go`: новый `RequireAdmin()` middleware на destructive endpoints (CRUD admins/servers/users, sync/restart). operator/viewer теперь только read.
- ✓ **Security HIGH (`e8449af`):**
  - `cluster/models.go SyncServer`: убран `RealityPrivateKey` (не передаётся peer'ам).
  - `mobile/auth.go Register`: `device_id` cap = 256 chars.
  - iOS `APIClient.dataWithFallback`: HTTP/80 legs пропускаются если есть `Authorization` header (no JWT in cleartext); + defensive nil header per leg.
- ✓ **Security MEDIUM (`e8449af`):** cluster push 10k users / 1k servers cap; admin password min 12 chars; `/health` не leak driver errors; KeychainHelper print() под `#if DEBUG`; nginx `Strict-Transport-Security` header.
- ✓ **iOS bugs HIGH (`e8449af`):**
  - `AppState.swift:138` operator-precedence bug в `repairConfigIfNeeded` исправлен (parens добавлены).
  - `KeychainHelper.save`: SecItemUpdate-then-Add вместо delete-then-add (atomic, без read window).
  - `ExtensionProvider.startTunnel`: `[weak self]` capture, guard на dealloc.
  - hardcoded "vpnConnectedAt" / "user_stopped_vpn" → `AppConstants.vpnConnectedAtKey` / `userStoppedVPNKey`.
- ✓ **Go review fixes (`e8449af`):** `err == db.ErrNotFound` → `errors.Is(err, db.ErrNotFound)` в `admin/users.go` (×2) + `admin/admins.go`.
- ✓ **Docs cleanup (`e8449af`):** README, OPERATIONS.md, troubleshooting.yaml, operations.yaml — оставшиеся `apple/` / `ChameleonVPN/` / `Chameleon.xcodeproj` ссылки заменены на новые имена.
- ✓ **Cosmetic:** `ConfigStore.clear()` убран двойной `KeychainHelper.delete("username")`; nginx `Strict-Transport-Security`.

---

## Launch analysis (2026-04-24)

Competitive comparison сделан в chat-сессии 2026-04-24. Источники: распарсенные
subscriptions конкурентов.

### Конкуренты проанализированы
- **MaxVPN** (`95.163.183.11/happ/...`) — VK Cloud MSK entry, exit на
  Hostinger/BuyVM/ICC/BlueVPS/CGI, VLESS Reality `:8443`, SNI=`www.apple.com`.
  Ни одной OVH-ноды.
- **Kosmos TunnelGuard** (`kosmos.tunnelguard.ru`) — Miran SPB entry (AS41722),
  proprietary `kosmos://` URL scheme, closed API с auth.
- **StrelkaVPN / net4.su** (`net4.su/keys/...`) — 54 конфига, все помечены
  🟢LTE. DDoS-Guard fronting, exit nodes **50% на Yandex Cloud**
  (AS200350, `84.201.*`, `51.250.*`) и VK Cloud (`95.163.183.*`) — RU-клауды с
  флагами "DE"/"NL"/"FI" = **relay architecture** (entry на whitelist ASN,
  внутренний chain к реальному заграничному exit). VLESS Reality `:443`,
  SNI=rotating RU-domains (`music.yandex.ru`, `eh.vk.ru`, `ads.adfox.ru`,
  `megafon.ru`, etc).

### Ключевые выводы
1. **OVH-гипотеза подтверждается 3:3** — все 3 проанализированных VPN избегают
   OVH. Ни одного контр-примера "OVH и работает на LTE".
2. **Порт `:443` не проблема** — StrelkaVPN работает на `:443`.
3. **SNI `ads.adfox.ru` валиден** — StrelkaVPN использует идентичный паттерн
   (`.ru`-домены), менять не надо.
4. **Relay-архитектура** (RU-entry → chain → foreign exit) — индустриальный
   стандарт для RU-targeted VPN. Даёт ASN-иммунитет: клиент видит RU-IP, DPI
   не может блокировать без collateral damage.
5. **Karing/Happ Plus technologically = наше приложение** (все на sing-box
   1.13+). Наши реальные пробелы — не в протоколах, а в iOS-платформенных
   фичах (widgets, shortcuts, live activity, on-demand). См. "Launch Checklist
   v1.0" в секции Now.

### Кандидаты хостинга (сводно)
**Для direct-exit** (простейший путь, без relay):
- Hetzner Helsinki/Falkenstein (AS24940) — €4.5/мес
- WAIcore Ltd (AS213887, DE) — мелкий VPN-френдли ASN
- Hostinger Lithuania (AS47583) — как MaxVPN
- BuyVM/FranTech DE (AS53667) — как MaxVPN

**Для RU-entry relay** (долгосрочное решение):
- Наш MSK relay `217.198.5.52` (Tatarstan-On-Line) — уже есть, бесплатно,
  но LTE-whitelist статус ASN **не проверен**
- Selectel MSK (AS49505) — крупный RU-хостер, €3/мес
- Timeweb MSK (AS9123) — как NL-нода, уже работаем с ним
- Yandex Cloud / VK Cloud — maximum-reliable ASN, **но VPN запрещён TOS**
  (StrelkaVPN нарушает, риск бана аккаунта)

### Проверенные факты (не забыть при следующем возврате к теме)
- `api.madfrog.online` → DNS A → `217.198.5.52` (MSK) **напрямую**, CF не в пути.
- DE/NL direct-IP `:443` HTTPS не даёт доступа к API — там sing-box Reality
  steal на `ads.adfox.ru`, Host=api.madfrog.online вернёт Яндекс-400.
  Единственный рабочий API-endpoint = MSK.
- DE/NL `:80` backend работает (HTTP 200 /health), но на RU LTE к OVH SYN
  блочится и на :80 тоже (ASN-level drop для всех портов).

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
