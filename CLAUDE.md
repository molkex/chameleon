# Chameleon VPN — Instructions for Claude Code

## Проект
Нативное VPN приложение (iOS + macOS) с собственным backend API. Монорепо: backend (Rust/Axum), admin SPA (React), iOS/macOS (Swift/SwiftUI + sing-box).

## Режим работы
Полная автономия. Выполняй ВСЕ операции без запроса подтверждения: git, файлы, деплой, Docker, cargo/npm, SSH. При препятствиях — решай сам.

## Структура проекта
```
chameleon/
├── backend/              # Rust backend (Axum + SQLx + fred)
│   ├── Cargo.toml        # Workspace root
│   ├── crates/
│   │   ├── chameleon-config/     # Settings, .env, validation
│   │   ├── chameleon-db/         # PgPool, 13 models, queries
│   │   ├── chameleon-auth/       # JWT, argon2/bcrypt, RBAC extractors
│   │   ├── chameleon-vpn/        # 8 protocols, engine, xray_api, links
│   │   ├── chameleon-api/        # Axum handlers, middleware
│   │   ├── chameleon-monitoring/ # Traffic collector, node metrics
│   │   └── chameleon-server/     # Binary entrypoint
│   ├── migrations/       # SQL migrations (sqlx)
│   ├── Dockerfile         # Multi-stage, non-root
│   └── docker-compose.yml # Production deployment
├── admin/                # React SPA админка
├── apple/                # iOS + macOS приложения
│   ├── ChameleonVPN/     # iOS target
│   ├── ChameleonVPNMac/  # macOS target
│   ├── PacketTunnel/     # VPN extension
│   ├── Shared/           # Общий код
│   └── Frameworks/       # libbox.xcframework
├── infrastructure/       # Docker, nginx, deploy
├── backend-legacy-python/ # OLD Python backend (reference only, DO NOT deploy)
└── PLAN.md
```

## Важные правила
- **Белые списки SNI:** ТОЛЬКО проверенные (НЕ google.com/cloudflare.com). Новые SNI проверять на блокировку РКН
- **Деплой DE:** основной сервер для нового проекта (162.19.242.30)
- **NL + Moscow:** НЕ ТРОГАТЬ — обслуживают текущих пользователей бота
- **sing-box:** версия 1.13 target
- **Xray-core:** v26.3.27

## Стек
- **Backend:** Rust 1.85, Axum 0.8, SQLx 0.8 (async PostgreSQL), fred 10 (Redis), jsonwebtoken, argon2
- **Admin:** React 19, TailwindCSS 4, shadcn/ui, TanStack Router+Query, Vite 7
- **iOS/macOS:** Swift 6, SwiftUI (iOS 17+ / macOS 14+), NetworkExtension, StoreKit 2, sing-box (libbox)
- **VPN (8 протоколов):** VLESS Reality TCP/gRPC, VLESS WS CDN, Hysteria2, WARP+ WireGuard + Finalmask, AnyTLS, NaiveProxy, XDNS, XICMP
- **Infra:** Docker, Nginx, PostgreSQL 16, Redis 7, Xray-core v26.3.27

## Серверы
| Сервер | IP | Роль |
|---|---|---|
| DE | 162.19.242.30 | Новый проект: backend + xray |
| NL | 147.45.252.234 | Бот (не трогать) |
| Moscow | 85.239.49.28 | Бот (не трогать) |
| YC Relay | 89.169.144.42 | Whitelist bypass relay |
| SPB Relay | 185.218.0.43 | Relay #2 |

## Система памяти
После значимых задач обновлять:
- `TROUBLESHOOTING.md` — баги и решения
- `ARCHITECTURE.md` — архитектурные решения
- `PLAN.md` — текущий план и прогресс

## Конфигурация
- **Config:** `backend/crates/chameleon-config/src/lib.rs` — Settings struct, env vars
- **Auth:** `backend/crates/chameleon-auth/` — JWT (jsonwebtoken), argon2, RBAC extractors
- **DB models:** `backend/crates/chameleon-db/src/models.rs` — 13 sqlx FromRow structs

## Ключевые файлы (Rust backend)
- `backend/crates/chameleon-vpn/src/engine.rs` — ChameleonEngine (центральный движок)
- `backend/crates/chameleon-vpn/src/xray_api.rs` — XrayAPI (Docker exec)
- `backend/crates/chameleon-vpn/src/protocols/` — 8 Protocol trait implementations
- `backend/crates/chameleon-vpn/src/links.rs` — subscription link generation
- `backend/crates/chameleon-auth/src/rbac.rs` — RBAC extractors (AuthAdmin, RequireOperator)
- `backend/crates/chameleon-auth/src/jwt.rs` — JWT create/verify
- `backend/crates/chameleon-auth/src/password.rs` — argon2 + bcrypt + SHA-256 legacy
- `backend/crates/chameleon-api/src/admin/` — Admin API handlers
- `backend/crates/chameleon-api/src/mobile/` — Mobile API handlers
- `backend/crates/chameleon-api/src/middleware/` — rate_limit, security_headers
- `backend/crates/chameleon-server/src/main.rs` — binary entrypoint
