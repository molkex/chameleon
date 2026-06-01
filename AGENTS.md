# Chameleon VPN — Instructions for Codex

## Проект

Нативное VPN приложение (iOS + macOS) с собственным backend API. Монорепо: backend (Go), admin SPA (React), iOS/macOS (Swift/SwiftUI + sing-box/libbox).

## Режим работы

- Сначала **согласуй подход** с пользователем (кратко: что планируешь, какие файлы затронешь).
- После согласования — работай автономно: git, файлы, деплой, Docker, SSH.
- При неожиданных проблемах — сообщи пользователю, не импровизируй молча.

## Документация — где что лежит

**Старт сессии:** прочитай [`docs/README.md`](docs/README.md) и [`docs/arch/overview.md`](docs/arch/overview.md) — за 2 минуты получишь карту проекта.

Структура `docs/` (введена 2026-05-28, см. [`docs/decisions/0006-yaml-state-md-narrative.md`](docs/decisions/0006-yaml-state-md-narrative.md)):

| Что нужно | Куда лезть |
|---|---|
| 30-сек снимок состояния (читать первым) | `docs/state/project.yaml` |
| Текущие IP / порты / ASC IDs / IAP states / платежи | `docs/state/*.yaml` (servers, app-store, runtime, domains, payment-providers) |
| Что чем покрыто тестами + как проверять каждый слой | `docs/state/test-map.yaml` (decision 0009) |
| Как развернуть NL / выпустить iOS / починить Apple reject / ops-runbook / debug VPN | `docs/playbooks/*.md` |
| Почему мы выбрали X (Go vs Rust, sing-box, IAP shape) | `docs/decisions/NNNN-*.md` (ADR pattern) |
| Что случилось когда упало (MED-015, Apple 2.3) | `docs/incidents/YYYY-MM-DD-*.md` |
| Дизайн системы / VPN-движок / backend-layout / payments | `docs/arch/{overview,vpn,backend,payments,mesh,target}.md` |
| Что делаем сейчас / что в очереди / что в done | `docs/roadmap.yaml` (один файл, не ROADMAP.md) |

**Правила:**
- **YAML** для current state (агенты парсят), **MD** для narrative (decisions/playbooks/incidents).
- **One source of truth.** Если тема в двух файлах — один устарел. Никаких `.md + .yaml` mirror'ов.
- `decisions/` и `incidents/` — **append-only**. Не редактируй старые ADR / post-mortem. Если решение изменилось — пиши новый ADR с `supersedes: NNNN` во frontmatter'е.
- При коммите: обнови `state/*.yaml` если факты изменились. Не нужно дублировать в README'ы.
- При завершении задачи: подвинь её из `roadmap.yaml#now/next` в `roadmap.yaml#done["YYYY-MM-DD"]`.
- При баге+решении: создай `docs/incidents/YYYY-MM-DD-<slug>.md`.
- **Тесты (decision 0009):** каждое изменение кода едет с тестом ИЛИ заводит/обновляет `TEST-*` пробел в `roadmap.yaml#next.testing`. Любое добавление/удаление теста обновляет `docs/state/test-map.yaml`. `test-map.yaml#verify` — канон команд проверки каждого слоя.

## Важные правила (operational)

- **SNI:** ТОЛЬКО проверенные (НЕ google.com / cloudflare.com). Новые SNI проверять на блокировку РКН. Текущий: `ads.adfox.ru`. См. [`docs/decisions/0002-singbox-1.13-vless-reality.md`](docs/decisions/0002-singbox-1.13-vless-reality.md).
- **NL — единственная production нода с 2026-05-25.** DE retired. Не упоминать `162.19.242.30` в новых deploy-скриптах. См. [`docs/state/servers.yaml`](docs/state/servers.yaml).
- **sing-box:** версия 1.13.x. ПЕРЕД генерацией конфигов читай https://sing-box.sagernet.org/migration/
- **Xray-core (server-side):** v25.12.8. **НЕ v26** — несовместим с sing-box 1.13.

## sing-box 1.13 (ОБЯЗАТЕЛЬНО)

- **ВСЕГДА** валидируй конфиг через `sing-box check -c config.json` на сервере ДО теста на iPhone.
- Если ошибка ссылается на доку — ПРОЧИТАЙ ЕЁ прежде чем фиксить.
- Собирай ВСЕ проблемы формата и исправляй РАЗОМ, не по одному полю.
- Route rules: `{"action":"sniff"}` первым, потом `{"protocol":"dns","action":"hijack-dns"}`.
- DNS серверы в 1.13 идут напрямую по умолчанию — `detour:"direct"` НЕ нужен.
- Deprecated: `dns.fakeip` (→ DNS server `type:"fakeip"`), `inet4_address` (→ `address:[]`), `strict_route`, `server_name` в DNS.
- sing-box `mux` (h2mux) **несовместим** с Xray server — не включай на клиенте.

## Качество iOS кода

- **ВСЕГДА** добавлять таймаут на сетевые операции (VPN connect, API calls, gRPC).
- VPN connect: если статус не `.connected` за 30 секунд → disconnect + показать ошибку.
- **НЕ оставлять** бесконечные retry / polling без максимума попыток.
- **НЕ блокировать** UI — все сетевые вызовы async.

## Деплой

- **NL deploy:** `cd backend && ./deploy.sh nl`. Подробно — [`docs/playbooks/deploy-nl.md`](docs/playbooks/deploy-nl.md).
- **iOS release via CLI:** [`docs/playbooks/ios-cli-release.md`](docs/playbooks/ios-cli-release.md).
- **Apple reject recovery:** [`docs/playbooks/apple-reject-recovery.md`](docs/playbooks/apple-reject-recovery.md).
- **Перед деплоем** сверяй API контракт backend ↔ iOS (URL пути, формат ответа, авторизация).
- **rsync:** ВСЕГДА exclude `.git`, `target/`, `node_modules/`, build artifacts.

## Стек

- **Backend:** Go 1.25 + Echo v4 + pgx/v5 + go-redis/v9 + zap — `backend/`
- **Admin SPA:** React 19, TailwindCSS 4, shadcn/ui, TanStack Router+Query, Vite 7 — `clients/admin/`
- **iOS/macOS:** Swift 6, SwiftUI (iOS 17+ / macOS 14+), NetworkExtension, StoreKit 2, sing-box (libbox 1.13) — `clients/apple/`
- **VPN:** VLESS Reality TCP (primary), sing-box клиент + Xray 25.12.8 сервер
- **Infra:** Docker + Nginx + PostgreSQL 16 + Redis 7, single-NL посткриз 2026-05-25

## Серверы

| Сервер | IP | Роль | Status |
|---|---|---|---|
| **NL** | 147.45.252.234 | Backend + VPN node (port 443), api.madfrog.online | 🟢 sole production |
| MSK relay | 217.198.5.52 | nginx upstream → NL:80 для api.madfrog.online | 🟢 active |
| SPB relay | 185.218.0.43 | tcp/stream forwarder → NL:443 | 🟢 active |
| DE | 162.19.242.30 | бывший backend + VPN | 🔴 RETIRED 2026-05-25 |

Полная карта — [`docs/state/servers.yaml`](docs/state/servers.yaml). Single-NL SPoF accepted — exit план через Hetzner Helsinki — [`docs/decisions/0004-single-nl-spof.md`](docs/decisions/0004-single-nl-spof.md).

## Домены

- **`madfrog.online`** apex — Cloudflare proxy → NL:80 (SSL=flexible). Публичный landing + admin SPA.
- **`api.madfrog.online`** — **НЕ через CF**. DNS A-record → MSK relay (217.198.5.52) → nginx upstream → NL:80. Так нужно, чтобы RU users обходили CF throttling.
- Legacy: `www.madfrog.online`, `mdfrog.site`, `razblokirator.ru` — алиасы → NL.
- Subdomains `bot.`, `crew.`, `speedtest.` всё ещё на легаси `85.239.49.28` — задача [`docs/state/domains.yaml`](docs/state/domains.yaml).

## Ключевые файлы

### Backend
- `backend/internal/vpn/clientconfig.go` — генерация sing-box конфига для iOS
- `backend/internal/vpn/engine.go` — VPN engine
- `backend/internal/api/{mobile,admin}/` — HTTP handlers
- `backend/internal/auth/` — JWT, device registration
- `backend/internal/asc/` — App Store Connect API client (added 2026-05-27, BE-01b)
- `backend/cmd/chameleon/main.go` — entrypoint

### iOS / macOS (target name: `MadFrogVPN`)
- `clients/apple/PacketTunnel/ExtensionProvider.swift` — sing-box lifecycle, startTunnel/stopTunnel
- `clients/apple/PacketTunnel/ExtensionPlatformInterface.swift` — bridge sing-box ↔ NetworkExtension
- `clients/apple/MadFrogVPN/Models/VPNManager.swift` — VPN connection management
- `clients/apple/MadFrogVPN/Models/AppState.swift` — high-level state, retry logic, scenePhase
- `clients/apple/MadFrogVPN/Models/SubscriptionManager.swift` — StoreKit 2
- `clients/apple/MadFrogVPN/Models/EventTracker.swift` — USR-09 Phase 2 telemetry (added 2026-05-28)
- `clients/apple/MadFrogVPN/Models/APIClient.swift` — все backend calls + race
- `clients/apple/Shared/Constants.swift` — `AppConstants.baseURL`, direct backend IPs (DE prune pending)
- `clients/apple/Shared/PlatformDevice.swift` — extension-safe device info

## Apple targets (4 штуки, один XcodeGen проект)

- **MadFrogVPN** (iOS app, bundle `com.madfrog.vpn`)
- **PacketTunnel** (iOS NE app-extension, bundle `com.madfrog.vpn.tunnel`)
- **MadFrogVPNMac** (macOS app, bundle `com.madfrog.vpn.mac`, отдельный App Store listing)
- **PacketTunnelMac** (macOS NE app-extension, bundle `com.madfrog.vpn.mac.tunnel`)
- **MadFrogWidget** (iOS app-extension, bundle `com.madfrog.vpn.widget`, since build 82)

SwiftUI / модели шарятся через `MadFrogVPN/` + `Shared/`. Платформ-специфичные API обёрнуты в `Shared/Platform*.swift` helpers.

## Libbox.xcframework (vendored, git-ignored ~494 MB)

Собирается из sing-box v1.13.5 через `make lib_apple` (sagernet/gomobile fork). Slices: `ios-arm64`, `ios-arm64_x86_64-simulator`, `macos-arm64_x86_64`. Info.plist каждого slice патчится для App Store валидации.

При чистом клоне — `clients/apple/scripts/fetch-libbox.sh` тянет xcframework (146M zip) из GitHub Release `libbox-v1.13.5` (`gh release download` + `ditto -x`, сохраняет macOS-симлинки). CI (`ios.yml`) гоняет его и собирает iOS+macOS + `build-for-testing` (тесты компилируются; НЕ запускаются — краш test-host в unsigned sim). Пере-залить после ребилда libbox: `ditto -c -k --keepParent Libbox.xcframework <zip>; gh release upload libbox-v1.13.5 <zip> --clobber`.

## Apple signing (для App Store Connect)

- ASC API key: `~/private_keys/AuthKey_6HX3DA4P2Y.p8`. Все ID-шники в [`docs/state/app-store.yaml`](docs/state/app-store.yaml).
- Distribution cert: автоматически фетчится через `signingStyle: automatic` + `-allowProvisioningUpdates` (см. [`docs/playbooks/ios-cli-release.md`](docs/playbooks/ios-cli-release.md)).
- Provisioning profiles: автоматически.
- Bundle IDs в Apple Developer portal имеют capabilities: APP_GROUPS (`group.com.madfrog.vpn`), NETWORK_EXTENSIONS (`packet-tunnel-provider`), APPLE_ID_AUTH (main app), ASSOCIATED_DOMAINS (main app).
- ⚠️ App Group привязка к bundle ID делается через Xcode Organizer **Distribute** UI, **не** через ASC API. Для full-automation без UI упираемся в это.

## Secrets

Когда юзер скидывает credentials (passwords, tokens, API keys, SSH access, Issuer ID, Key ID и т.д.) — **немедленно** сохрани в `~/.secrets.env` через skill `save-secrets`. Это касается данных в сообщениях, файлах, скриншотах, .env файлах — любых источниках. Не жди конца задачи.
