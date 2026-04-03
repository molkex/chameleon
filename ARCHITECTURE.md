# Chameleon VPN — Architecture

## Обзор
Монорепо для VPN сервиса: backend API (FastAPI), admin SPA (React), нативные приложения iOS/macOS (SwiftUI + sing-box).

## Компоненты

### Backend (`backend/`)
FastAPI приложение, единая точка входа для всех API.

**Модули:**
- `app/vpn/` — **Chameleon Core** — модульное VPN ядро (см. ниже)
- `app/monitoring/` — метрики нод, мониторинг прокси, сбор трафика
- `app/auth/` — JWT аутентификация (admin + mobile), RBAC, StoreKit verification
- `app/api/mobile/` — API для приложений (auth, config, subscription, servers)
- `app/api/admin/` — API для админки (stats, users, nodes, settings)
- `app/api/webhooks/` — Apple Server Notifications v2
- `app/database/` — SQLAlchemy модели, Alembic миграции

**Ключевые решения:**
- pydantic-settings вместо os.getenv() — типизированная конфигурация с валидацией
- joserfc для JWT — замена abandoned python-jose
- FastAPI Depends() вместо синглтонов — testable, DI
- Async SQLAlchemy 2.0 — полностью асинхронный стек

---

## Chameleon Core (`app/vpn/`)

Модульная архитектура VPN ядра с plugin-системой протоколов и server-controlled приоритизацией.

### Protocol Plugin System (`app/vpn/protocols/`)

Каждый протокол реализует ABC и регистрируется в реестре:

```
protocols/
├── base.py          # ABC — ProtocolPlugin interface
├── registry.py      # ProtocolRegistry — register/get/list plugins
├── vless_reality.py # VLESS Reality TCP + gRPC
├── vless_cdn.py     # VLESS WS через Cloudflare CDN
├── hysteria2.py     # Hysteria2 UDP (salamander obfs)
├── warp.py          # WARP+ WireGuard + Finalmask
├── anytls.py        # AnyTLS — маскировка TLS proxy
└── naiveproxy.py    # NaiveProxy — Chrome fingerprint (sing-box 1.13)
```

Добавление нового протокола: создать файл, реализовать ABC, зарегистрировать в `__init__.py`.

### ChameleonShield (`app/vpn/shield.py`)
Server-controlled protocol priorities. Сервер определяет порядок и доступность протоколов, клиент получает готовый приоритизированный список. Позволяет мгновенно реагировать на блокировки без обновления приложения.

### ChameleonEngine (`app/vpn/engine.py`)
Центральный движок, координирующий все VPN-подсистемы: протоколы, shield, fallback, padding, SNI rotation.

### XrayAPI (`app/vpn/xray_api.py`)
Управление пользователями Xray через gRPC Stats API (порт 10085). Динамическое добавление/удаление пользователей, получение статистики трафика.

### Config Versioning (`app/vpn/config_version.py`)
Hash-based версионирование конфигов. Клиент отправляет свою версию, сервер отвечает только при наличии обновлений. Снижает трафик и нагрузку.

### Fallback Chain (`app/vpn/fallback.py`)
Упорядоченная цепочка fallback-протоколов. Строит `urltest`/`selector` outbound-группы с учётом приоритетов shield и доступности нод.

### Traffic Padding (`app/vpn/padding.py`)
Anti-fingerprinting: добавляет padding к outbound-конфигам для маскировки характерных размеров пакетов.

### SNI Rotation (`app/vpn/sni_rotation.py`)
Health-aware ротация SNI. Отслеживает успешность/блокировку каждого SNI через Redis, автоматически исключает заблокированные.

### Pull-based Node API (`app/vpn/node_api.py`)
Ноды (NL, DE) сами запрашивают конфигурацию с backend по API key. Заменяет push-подход через SSH/paramiko. Безопаснее, проще масштабировать.

### Webhook Events (`app/vpn/webhooks.py`)
Event emitter (`WebhookEmitter`). Генерирует события (user_created, config_updated, node_offline и т.д.) для внешних интеграций.

### Rate Limiter (`app/vpn/rate_limiter.py`)
Per-user rate limiting по объёму трафика. Redis-based, с configurable лимитами.

### Прочие модули
| Файл | Назначение |
|---|---|
| `links.py` | Генерация VLESS/HY2/WG subscription links |
| `users.py` | Управление VPN-пользователями (create, activate, extend) |
| `nodes.py` | Управление нодами, circuit breaker |
| `stats.py` | Кеширование и получение статистики трафика |
| `singbox_config.py` | Генерация sing-box JSON конфигов (smart, mobile, minimal) |
| `config_tags.py` | Конфиг-теги (smart, antiblock, fullvpn, fragment, warp и др.) |
| `antiblock_config.py` | Конфиг для обхода блокировок (домены, маршруты) |
| `device_limiter.py` | Лимит устройств per-user |
| `domain_parser.py` | Парсинг client IP из Xray access log, HWID tracking |
| `vpn_helpers.py` | Хелперы: username generation, server resolution |
| `amneziawg.py` | AmneziaWG 2.0 управление |
| `config/` | Конфигурационные файлы протоколов |

---

## VPN Протоколы (10)

| # | Протокол | Порт | Назначение |
|---|---|---|---|
| 1 | VLESS Reality TCP | 2096 | Основной — обход DPI |
| 2 | VLESS Reality gRPC | 2098 | Backup |
| 3 | VLESS WS CDN | 2099 | CDN fallback через Cloudflare |
| 4 | Hysteria2 UDP | 8443 | Быстрый, для видео |
| 5 | AmneziaWG 2.0 | varies | Anti-DPI WireGuard fork |
| 6 | WARP+ WireGuard + Finalmask | 2408 | Маскировка через Cloudflare |
| 7 | AnyTLS | TBD | Маскировка TLS proxy (sing-box 1.12+) |
| 8 | NaiveProxy | TBD | Chrome fingerprint (sing-box 1.13) |
| 9 | XDNS | 53 | Аварийный DNS tunnel |
| 10 | XICMP | — | Аварийный ICMP tunnel |

---

### Admin SPA (`admin/`)
React 19 SPA с TanStack Router/Query.

**Страницы:** Dashboard, VPN Users, Nodes, Monitor, Protocols, Settings, Admins, Diagnostics, Subscriptions (App Store)

### Apple Apps (`apple/`)
```
apple/
├── ChameleonVPN/     # iOS app (SwiftUI)
├── ChameleonVPNMac/  # macOS app (SwiftUI + menu bar)
├── PacketTunnel/     # VPN extension (shared)
├── Shared/           # Общий код (Networking, Models, VPN)
└── Frameworks/       # libbox.xcframework (sing-box 1.13)
```

**Ключевые решения:**
- Shared/ — общий код между iOS и macOS (APIClient, AuthManager, KeychainHelper)
- PacketTunnel — один провайдер для обоих платформ
- StoreKit 2 — нативные подписки (server-side verification)
- Sign in with Apple — основная аутентификация

## Auth Flow
```
iOS/macOS App → Sign in with Apple → identity_token
  → POST /api/v1/mobile/auth/apple → verify with Apple JWKS
  → find/create User (apple_id) → issue JWT pair
  → access_token (15min) + refresh_token (90d)

GET /api/v1/mobile/config → sing-box JSON
  → App saves to App Groups → PacketTunnel reads
```

## Database
PostgreSQL с Alembic миграциями. User модель имеет `apple_id` + `telegram_id` (nullable) для совместимости.

## Инфраструктура
- **Main (<YOUR_SERVER_IP>)** — основной backend + xray для приложений
- **Node 1 (<YOUR_SERVER_IP>)** — xray нода
- **Relay 1 (<YOUR_SERVER_IP>)** — relay server
- Docker + Nginx reverse proxy
- Xray-core v26.3.27 + sing-box 1.13 target + AmneziaWG 2.0

## Решения и trade-offs
| Решение | Альтернатива | Почему выбрали |
|---|---|---|
| joserfc | PyJWT, python-jose | python-jose abandoned, PyJWT нет JWE. joserfc — modern, typed |
| pydantic-settings | dotenv + os.getenv | Валидация при старте, type safety |
| TanStack Router | React Router | Type-safe routing, lazy loading |
| sing-box 1.13 | 1.12 stable | NaiveProxy outbound, улучшения DNS |
| Protocol plugins (ABC) | Monolithic controller | Легко добавлять протоколы, testable |
| Pull-based node API | Push via SSH/paramiko | Безопаснее, масштабируемее |
| ChameleonShield | Client-side priorities | Мгновенная реакция на блокировки без обновления приложения |
| Swift 6 strict concurrency | Swift 5 | Data-race safety, modern patterns |

---
*Обновлено: 2026-03-28*
