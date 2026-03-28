# Chameleon VPN — Implementation Plan

> Новый продукт: нативные iOS/macOS приложения + собственный backend API.
> Telegram бот остаётся в отдельном репо на поддержке, новый фокус — приложения.

---

## Tech Stack (2026, выбран после research)

### Backend
| Компонент | Технология | Версия | Почему |
|---|---|---|---|
| Framework | **FastAPI** | 0.135+ | Async, OpenAPI, DI. v0.135: enforces JSON Content-Type, Starlette 0.46+ |
| Config | **pydantic-settings** | 2.x | Typed .env, валидация при старте |
| ORM | **SQLAlchemy** | 2.0+ | Async engine, mapped_column |
| Migrations | **Alembic** | 1.14+ | Production-proven |
| JWT | **joserfc** | 1.0+ | Замена python-jose (abandoned). JWS/JWE/JWK, type hints, активно поддерживается |
| Auth | **Sign in with Apple** + device auth | — | Apple JWKS verification → joserfc |
| StoreKit | **app-store-server-library** | 3.0.0 | **Apple official** Python lib! JWS verify, Server Notif v2, App Store Server API |
| Cache | **Redis** | 7.x | Сессии, кеш, rate limiting |
| DB | **PostgreSQL** | 16+ | JSONB, production-proven |
| HTTP client | **httpx** | 0.28+ | Async, для Apple API |
| Task queue | **arq** (если нужно) | 0.26+ | Lightweight async Redis queue |

### Admin SPA
| Компонент | Технология | Версия | Почему |
|---|---|---|---|
| Framework | **React** | 19.2 | Actions API, useActionState, Server Components |
| Routing | **TanStack Router** | 1.x | Type-safe, lazy loading |
| Data | **TanStack Query** | 5.x | Stale-while-revalidate, mutations |
| UI | **shadcn/ui** | latest (2026) | Теперь поддерживает Base UI + Radix. Visual Builder. 75k+ stars |
| Styling | **TailwindCSS** | 4.x | JIT, container queries |
| Charts | **Recharts** | 3.x | Проверенное решение |
| Build | **Vite** | 6.x | Быстрый HMR, tree-shaking |

### iOS / macOS
| Компонент | Технология | Версия | Почему |
|---|---|---|---|
| Language | **Swift** | 6.x | Strict concurrency, data-race safety |
| UI | **SwiftUI** | iOS 17+ / macOS 14+ | Observation framework, новые APIs |
| VPN | **NetworkExtension** | — | PacketTunnel (iOS), SystemExtension (macOS) |
| VPN engine | **sing-box (libbox)** | **1.13 target** | AnyTLS, NaiveProxy outbound, TLS fragment, refactored DNS |
| Payments | **StoreKit 2** | — | Нативный async/await API |
| Auth | **AuthenticationServices** | — | Sign in with Apple |
| Networking | **URLSession** | async/await | Нативный, не нужен Alamofire |
| Storage | **Keychain** + **UserDefaults** (App Groups) | — | Secure token storage + shared state |

### VPN Protocols
| # | Протокол | Транспорт | Порт | Статус |
|---|---|---|---|---|
| 1 | VLESS Reality | TCP (Vision flow) | 2096 | **Основной** — лучший для обхода DPI |
| 2 | VLESS Reality | gRPC | 2098 | Backup |
| 3 | VLESS WS | CDN (Cloudflare) | 2099 | CDN fallback |
| 4 | Hysteria2 | UDP (salamander) | 8443 | Быстрый, для видео |
| 5 | AmneziaWG 2.0 | UDP (WireGuard) | varies | Anti-DPI WireGuard fork |
| 6 | WARP+ WireGuard | WireGuard → CF + Finalmask | 2408 | Маскировка через Cloudflare |
| 7 | AnyTLS | TCP | TBD | sing-box 1.12+, маскировка TLS proxy |
| 8 | NaiveProxy | QUIC/H2 | TBD | sing-box 1.13, Chrome fingerprint |
| 9 | XDNS | DNS tunnel (emergency) | 53 | Аварийный канал |
| 10 | XICMP | ICMP tunnel (emergency) | — | Аварийный канал |

### Infrastructure
| Компонент | Технология |
|---|---|
| Containers | Docker + docker-compose |
| Reverse proxy | Nginx |
| CI/CD | GitHub Actions |
| Monitoring | Prometheus + custom metrics endpoint |
| VPN server | Xray-core v26.3.27 |

---

### Research Findings (2026-03-27)

**Ключевые находки:**
1. **app-store-server-library 3.0.0** (Apple official) — НЕ нужно писать свою JWS verification. Библиотека делает всё: verify transactions, Server Notifications v2, certificate chain validation
2. **Swift 6.2 "Approachable Concurrency"** — @MainActor-by-default, @concurrent attribute. Упрощает concurrency в SwiftUI
3. **sing-box 1.13 target** — AnyTLS + TLS fragment + refactored DNS + NaiveProxy outbound (was 1.12 stable)
4. **libbox IPC** — gRPC-based CommandServer/CommandClient для связи host app ↔ PacketTunnel
5. **sing-box-for-apple** (SagerNet) — reference implementation iOS/macOS клиента sing-box
6. **Hiddify** — Flutter cross-platform, 23k+ stars. Но Flutter = overhead для VPN
7. **Amnezia VPN** — Go-based multi-protocol. macOS использует System Extension
8. **Outline** (Google) — Electron + Cordova. Хорошая архитектура серверной части (outline-server)
9. **Refine v5** — headless admin framework на TanStack. Но наш custom подход с shadcn/ui уже оптимален
10. **Docker:** python:3.13-slim (НЕ alpine — manylinux wheels не работают). Non-root user. HEALTHCHECK обязателен

**Паттерны для iOS приложения (из sing-box-for-apple):**
- `CommandServer` в PacketTunnel, `CommandClient` в host app
- Config передаётся как JSON через App Groups
- NE suspension handler с 1-min auto-wake timer
- Avoid `sysctl` в PacketTunnel sandbox (уже знаем — был краш)

---

## Серверы

| Сервер | IP | Роль (новый проект) |
|---|---|---|
| **DE** | 162.19.242.30 | Backend API + xray нода для приложений |
| **NL** | 147.45.252.234 | Xray нода (позже переключим с бота) |
| **Moscow** | 85.239.49.28 | Пока работает бот. Позже → основной backend |
| **YC Relay** | 89.169.144.42 | Relay для whitelist bypass |

---

## Архитектура

```
┌─────────────────┐     ┌─────────────────┐
│   iOS App        │     │  macOS App       │
│   (SwiftUI +     │     │  (SwiftUI +      │
│    sing-box)     │     │   sing-box)      │
└────────┬─────────┘     └────────┬─────────┘
         │ HTTPS                   │ HTTPS
         ▼                         ▼
┌──────────────────────────────────────────┐
│            Nginx (DE server)             │
│  /api/v1/mobile/* → backend              │
│  /api/v1/admin/* → backend               │
│  /admin/app/* → React SPA               │
│  /sub/* → subscription endpoints         │
│  /webhooks/* → Apple notifications       │
└────────────────────┬─────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────┐
│        FastAPI Backend (Docker)          │
│                                          │
│  ┌─────────┐ ┌──────────┐ ┌──────────┐ │
│  │ Mobile  │ │ Admin    │ │ VPN Core │ │
│  │ API     │ │ API      │ │          │ │
│  └─────────┘ └──────────┘ └──────────┘ │
│        │           │            │        │
│        ▼           ▼            ▼        │
│  ┌──────────────────────────────────┐   │
│  │    PostgreSQL  +  Redis          │   │
│  └──────────────────────────────────┘   │
└──────────────────────────────────────────┘
         │
         │ SSH/paramiko (node sync)
         ▼
┌─────────────────┐  ┌─────────────────┐
│  NL Xray Node   │  │  DE Xray Node   │
│  147.45.252.234  │  │  (local)        │
└─────────────────┘  └─────────────────┘
```

---

## Auth Flow (приложения)

```
1. Первый запуск → Sign in with Apple
   App: ASAuthorizationController → identityToken (JWT)
   App → POST /api/v1/mobile/auth/apple {identity_token, device_id}
   Backend: verify JWT с Apple JWKS → extract sub (apple_id)
   Backend: find/create User → issue access_token (15min) + refresh_token (90d)

2. Повторный запуск → auto-refresh
   App: Authorization: Bearer {access_token}
   401 → POST /api/v1/mobile/auth/refresh {refresh_token}
   Backend: verify + rotate refresh_token → new pair

3. Получение VPN конфига
   App → GET /api/v1/mobile/config?mode=smart
   Backend: generate sing-box JSON → return
   App: save to App Groups → PacketTunnel reads it
```

---

## StoreKit 2 Flow

```
App                          Backend                   Apple
 │                              │                        │
 │ Product.products(for:ids)    │                        │
 │◄─────────────────────────────│                        │
 │                              │                        │
 │ product.purchase()           │                        │
 │─────────────────────────────────────────────────────►│
 │                              │                        │
 │ Transaction.currentEntitlements                       │
 │◄─────────────────────────────────────────────────────│
 │                              │                        │
 │ POST /subscription/verify    │                        │
 │ {signedTransactionInfo}      │                        │
 │─────────────────────────────►│ verify JWS             │
 │                              │ update User.subscription│
 │ ◄── {status: active}        │                        │
 │                              │                        │
 │                              │◄──── Server Notif v2   │
 │                              │ (renew/expire/refund)  │
 │                              │ update subscription    │

Product IDs:
  com.chameleon.vpn.monthly     — 1 month
  com.chameleon.vpn.quarterly   — 3 months
  com.chameleon.vpn.yearly      — 1 year
```

---

## API Endpoints

### Mobile API (`/api/v1/mobile/`)

| Method | Path | Auth | Описание |
|---|---|---|---|
| POST | `/auth/apple` | - | Sign in with Apple → JWT pair |
| POST | `/auth/refresh` | refresh_token | Обновить токены |
| GET | `/config` | Bearer | sing-box JSON конфиг (`?mode=smart\|fullvpn\|minimal`) |
| GET | `/servers` | Bearer | Список серверов с health/ping |
| GET | `/subscription` | Bearer | Статус подписки |
| POST | `/subscription/verify` | Bearer | Проверка StoreKit receipt |
| GET | `/support/messages` | Bearer | Сообщения поддержки |
| POST | `/support/messages` | Bearer | Отправить сообщение |

### Admin API (`/api/v1/admin/`)

| Method | Path | Auth | Описание |
|---|---|---|---|
| POST | `/auth/login` | - | JWT login (httpOnly cookie) |
| POST | `/auth/refresh` | cookie | Обновить токены |
| GET | `/stats/dashboard` | admin | Метрики: пользователи, подписки, revenue |
| GET | `/users` | operator+ | Список пользователей |
| POST | `/users` | operator+ | Создать пользователя |
| GET | `/nodes` | viewer+ | Статус нод |
| GET | `/monitor` | viewer+ | Мониторинг |
| GET | `/protocols` | viewer+ | Конфигурация протоколов |
| PATCH | `/settings/branding` | admin | Настройки бренда |
| PATCH | `/settings/warp` | admin | WARP настройки |
| GET | `/admins` | admin | Список админов |
| POST | `/admins` | admin | Создать админа |
| GET | `/subscriptions` | operator+ | App Store подписки |

### Webhooks

| Method | Path | Auth | Описание |
|---|---|---|---|
| POST | `/webhooks/appstore` | Apple JWS | Server Notifications v2 |

### Public

| Method | Path | Auth | Описание |
|---|---|---|---|
| GET | `/sub/{token}` | token | Subscription URL (VLESS links) |
| GET | `/sub/{token}/smart` | token | sing-box JSON config |

---

## Database Model Changes

```python
class User(Base):
    # Existing (keep)
    id: int (PK)
    marzban_username: str
    vpn_uuid: str
    vpn_short_id: str
    subscription_end: datetime
    is_active: bool
    device_limit: int | None

    # Modified
    telegram_id: int | None      # nullable (was required)

    # NEW
    apple_id: str | None         # Apple Sign In 'sub' claim
    device_id: str | None        # Anonymous device ID
    auth_provider: str           # "apple" | "device" | "telegram"
    original_transaction_id: str | None  # App Store subscription
    app_store_product_id: str | None     # Current product

    # Remove (bot-specific)
    # bot_blocked_at — not needed
    # notified_3d, notified_1d — not needed
    # referral_source — redesign later
```

---

## Порядок реализации

### Фаза 1: Backend Core (текущая сессия)
- [x] Создать структуру проекта
- [x] Перенести файлы
- [x] Модульная Chameleon Core архитектура (`app/vpn/`)
- [x] Protocol Plugin System — ABC base + Registry (`app/vpn/protocols/`)
- [x] 6 протоколов как плагины: VlessReality, VlessCdn, Hysteria2, Warp, AnyTLS, NaiveProxy
- [x] ChameleonShield — server-controlled protocol priorities (`app/vpn/shield.py`)
- [x] XrayAPI — dynamic user management via gRPC Stats API (`app/vpn/xray_api.py`)
- [x] ChameleonEngine — центральный движок (`app/vpn/engine.py`)
- [x] Config Versioning — hash-based config versions (`app/vpn/config_version.py`)
- [x] Fallback Chain — ordered fallback/selector logic (`app/vpn/fallback.py`)
- [x] Traffic Padding — anti-fingerprinting padding (`app/vpn/padding.py`)
- [x] SNI Rotation — health-aware SNI rotation (`app/vpn/sni_rotation.py`)
- [x] Pull-based Node API — nodes pull config via API key (`app/vpn/node_api.py`)
- [x] Webhook Events — event emitter for integrations (`app/vpn/webhooks.py`)
- [x] Rate Limiter — per-user traffic rate limiting (`app/vpn/rate_limiter.py`)
- [x] Link generation module (`app/vpn/links.py`)
- [x] User/node management modules (`app/vpn/users.py`, `app/vpn/nodes.py`)
- [ ] `pyproject.toml` с зависимостями
- [ ] `app/config.py` — pydantic-settings (из config_old.py)
- [ ] `app/main.py` — FastAPI app factory
- [ ] `app/dependencies.py` — DI
- [ ] Рефакторинг imports во всех перенесённых файлах
- [ ] `app/database/models.py` — добавить apple_id, storekit поля
- [ ] Alembic baseline migration
- [ ] Admin API endpoints — проверить что работают
- [ ] `/sub/{token}` endpoint

### Фаза 2: Mobile API + Auth
- [ ] `app/auth/mobile_auth.py` — Apple Sign In verification
- [ ] `app/auth/storekit.py` — JWS verification
- [ ] `app/api/mobile/auth.py` — login/refresh endpoints
- [ ] `app/api/mobile/config.py` — sing-box config endpoint
- [ ] `app/api/mobile/servers.py` — server list
- [ ] `app/api/mobile/subscription.py` — status + verify
- [ ] `app/api/webhooks/appstore.py` — Server Notifications v2

### Фаза 3: Admin SPA
- [ ] Очистить страницы от bot-специфичного
- [ ] `subscriptions.tsx` — App Store подписки
- [ ] Обновить vpn-users под apple_id
- [ ] Build + test

### Фаза 4: iOS App
- [ ] Xcode project setup (app + PacketTunnel)
- [ ] `Shared/Networking/APIClient.swift`
- [ ] `Shared/Networking/AuthManager.swift`
- [ ] VPNManager + PacketTunnelProvider (sing-box 1.12)
- [ ] Sign in with Apple flow
- [ ] StoreKit 2 paywall + purchase
- [ ] HomeView, ServersView, SettingsView
- [ ] Пересобрать libbox.xcframework (sing-box 1.12)

### Фаза 5: macOS App
- [ ] macOS target + SystemExtension
- [ ] Menu bar (NSStatusItem)
- [ ] Share Shared/ code
- [ ] Main window + Preferences

### Фаза 6: Deploy
- [ ] Docker compose для DE сервера
- [ ] Nginx config
- [ ] deploy_remote.py (упрощённый)
- [ ] E2E тест: app → DE backend → VPN

---

## Файловая карта (что откуда)

```
Новый файл                          ← Источник                              Действие
─────────────────────────────────────────────────────────────────────────────────────
backend/app/config.py               ← bot/config.py                         REWRITE (pydantic-settings)
backend/app/main.py                 ← bot/admin/admin_app.py                REWRITE (чистый FastAPI)
backend/app/dependencies.py         ← NEW                                   NEW
backend/app/database/models.py      ← bot/database/models.py                MIGRATE (+apple_id, storekit)
backend/app/database/db.py          ← bot/database/db.py                    MIGRATE (minimal changes)
backend/app/vpn/xray_controller.py  ← bot/services/xray_controller.py       MIGRATE (fix imports)
backend/app/vpn/singbox_config.py   ← bot/services/singbox_config.py        MIGRATE (fix imports)
backend/app/vpn/config_tags.py      ← bot/services/config_tags.py           MIGRATE (fix imports)
backend/app/vpn/antiblock_config.py ← bot/services/antiblock_config.py      MIGRATE (fix imports)
backend/app/vpn/device_limiter.py   ← bot/services/device_limiter.py        MIGRATE (fix imports)
backend/app/vpn/domain_parser.py    ← bot/services/domain_parser.py         MIGRATE (fix imports)
backend/app/vpn/vpn_helpers.py      ← bot/services/vpn_helpers.py           MIGRATE (fix imports)
backend/app/monitoring/node_metrics.py    ← bot/services/node_metrics.py    MIGRATE
backend/app/monitoring/proxy_monitor.py   ← bot/services/proxy_monitor.py   MIGRATE (remove TG notifs)
backend/app/monitoring/traffic_collector.py ← bot/services/traffic_collector.py MIGRATE
backend/app/auth/admin_auth.py      ← bot/admin/auth.py                     MIGRATE (joserfc)
backend/app/auth/rbac.py            ← bot/admin/api/v1/deps.py              MIGRATE
backend/app/auth/mobile_auth.py     ← NEW                                   NEW
backend/app/auth/storekit.py        ← NEW                                   NEW
backend/app/api/admin/*.py          ← bot/admin/api/v1/*.py                 MIGRATE (fix imports)
backend/app/api/mobile/*.py         ← NEW                                   NEW
backend/app/api/webhooks/appstore.py ← NEW                                  NEW
admin/src/pages/*.tsx               ← frontend/src/pages/*.tsx               MIGRATE (remove bot stuff)
apple/**/*.swift                    ← ChameleonVPN/**/*.swift                REWRITE
```
