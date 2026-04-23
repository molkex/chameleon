# Chameleon VPN — Architecture Wiki

> 🤖 Mirror: [agent-readable YAML](operations.yaml) — keep in sync. Edit either, sync the other.

> Последнее обновление: 2026-04-10

---

## Содержание

1. [Обзор системы](#1-обзор-системы)
2. [Серверная инфраструктура](#2-серверная-инфраструктура)
3. [Трафик и маршрутизация](#3-трафик-и-маршрутизация)
4. [Backend (Go)](#4-backend)
5. [VPN Engine (sing-box)](#5-vpn-engine-sing-box)
6. [Cluster Mesh Sync](#6-cluster-mesh-sync)
7. [База данных](#7-база-данных)
8. [Аутентификация](#8-аутентификация)
9. [iOS + macOS приложения](#9-ios--macos-приложения)
10. [Admin SPA](#10-admin-spa)
11. [Deploy](#11-deploy)
12. [Scripts и Cron](#12-scripts-и-cron)
13. [Критические правила](#13-критические-правила)
14. [Диагностика](#14-диагностика)
15. [История решённых проблем](#15-история-решённых-проблем)

---

## 1. Обзор системы

**Chameleon VPN** — нативное VPN-приложение (iOS) с собственным backend и мультинодовой инфраструктурой.

### Стек
| Компонент | Технология |
|---|---|
| Backend API | Go, Echo v4, PostgreSQL 16, Redis 7 |
| VPN протокол | VLESS Reality TCP (sing-box клиент + sing-box-fork сервер) |
| iOS приложение | Swift 6, SwiftUI, NetworkExtension, libbox 1.13.5 |
| Admin SPA | React 19, TailwindCSS 4, shadcn/ui, TanStack Router+Query |
| Инфраструктура | Docker, Nginx, OVH/Timeweb/SprintHost |

### Принципы архитектуры
1. **Автономные ноды** — каждая нода самодостаточна (своя БД, Redis, sing-box)
2. **Sing-box вне Compose** — отдельный контейнер, деплой не убивает VPN-соединения
3. **Cluster Sync опционален** — сбой синхронизации не ломает локальную ноду
4. **Zero-downtime пользователи** — User API для добавления/удаления без перезапуска
5. **Reality ключи в БД** — единственный источник правды, нет рассинхрона файлов

---

## 2. Серверная инфраструктура

### Серверы

| Сервер | IP | Роль | Хостинг | SSH |
|---|---|---|---|---|
| **DE (Main)** | `162.19.242.30` | Backend API + VPN нода | OVH Frankfurt | `ubuntu@162.19.242.30` |
| **NL (nl2)** | `147.45.252.234` | Backend + VPN нода | Timeweb Cloud | `root@147.45.252.234` |

**Legacy (не используем, вскоре отключить):** `85.239.49.28` (старый RazblokiratorBot), `185.218.0.43` (SPB Relay SprintHost), `89.169.144.42` (YC Relay).

### Домены и Cloudflare (обновлено 2026-04-14)
Все домены — через Cloudflare (proxied, SSL=flexible), DNS A-записи → DE `162.19.242.30`.

| Домен | Роль |
|---|---|
| `madfrog.online` + `www` | Основной: API + маркетинговый лендинг (`backend/landing/`) |
| `mdfrog.site` + `www` | Тот же лендинг (второй домен на случай блокировки) |
| `razblokirator.ru` | Legacy — админка + старые iOS-клиенты, всё ещё работает |

**iOS клиент**: `AppConfig.baseURL = "https://madfrog.online"` (см. `clients/apple/Shared/Constants.swift`).

- Admin UI (legacy): `https://razblokirator.ru/clients/admin/app/`
- Admin UI (новый): `https://madfrog.online/clients/admin/app/`
- Лендинг: `https://madfrog.online/` (served nginx из volume `./landing`)
- Subscription: `https://madfrog.online/sub/{token}`

**Nginx serving лендинга** (`backend/nginx.conf`):
```nginx
location = / {
    root /usr/share/nginx/html/landing;
    try_files /index.html =404;
}
```
Volume mount: `./landing:/usr/share/nginx/html/landing:ro`

### Порты на нодах
| Порт | Сервис |
|---|---|
| `2096` | VPN (VLESS Reality, sing-box) |
| `8000` | Backend API (chameleon) |
| `9090` | Clash API (sing-box внутренний, только localhost) |
| `15380` | User API (sing-box fork, только localhost) |
| `5432` | PostgreSQL (только localhost) |
| `6379` | Redis (только localhost) |
| `80/443` | Nginx (admin SPA + reverse proxy) |

---

## 3. Трафик и маршрутизация

### Полный путь пакета (iPhone → интернет)

```
iPhone
  │
  ├── [TUN interface, MTU 1400, system stack]
  │
  ├── sing-box (libbox 1.13.5 внутри PacketTunnel)
  │     │
  │     ├── Route rules (ПОРЯДОК КРИТИЧЕН):
  │     │     1. sniff (определить протокол)
  │     │     2. hijack-dns (перехватить DNS запросы)
  │     │     3. clash-direct (bypass если режим direct)
  │     │     4. QUIC reject (block UDP 443 — no_drop: true)
  │     │     5. private IPs → direct (LAN не туннелируем)
  │     │     6. всё остальное → Proxy selector
  │     │
  │     ├── DNS:
  │     │     FakeIP (198.18.0.0/15) — для приложений
  │     │     Remote DoH: 1.1.1.1 (через VPN)
  │     │     Direct DoH: 8.8.8.8 (для bypass трафика)
  │     │
  │     └── Outbound selector "Proxy":
  │           ├── Manual выбор: DE / NL / Russia→DE / Russia→NL
  │           └── Auto (urltest, интервал 3 мин, tolerance 100ms)
  │
  └── [VLESS Reality TCP + xtls-rprx-vision]
        │
        ├── 🇩🇪 DE direct:  162.19.242.30:2096
        └── 🇳🇱 NL direct:  147.45.252.234:2096
              │
              ▼
        sing-box-fork (сервер, v1.13.6-userapi)
              │
              └── direct outbound → интернет
```

### Reality TLS — как это работает
Reality — это маскировка TLS под легитимный сайт (SNI):
- Клиент: делает TLS ClientHello с SNI = `ads.adfox.ru`
- Сервер: если знает Reality private key → отвечает VPN-трафиком
- Незнающий наблюдатель видит обычный TLS handshake к `ads.adfox.ru`
- **SNI**: `ads.adfox.ru` — проверен, не блокируется РКН

---

## 4. Backend (Go)

### Структура директорий

```
backend/
├── cmd/chameleon/main.go     — entrypoint, порядок инициализации
├── internal/
│   ├── api/
│   │   ├── server.go         — HTTP сервер, middleware, роуты
│   │   ├── mobile/           — Mobile API (регистрация, конфиг, Apple)
│   │   └── clients/admin/            — Admin API (users, nodes, servers, stats)
│   ├── cluster/
│   │   ├── sync.go           — HTTP pull/push reconciliation
│   │   ├── pubsub.go         — Redis Pub/Sub subscriber
│   │   ├── routes.go         — /api/cluster/* endpoints + auth middleware
│   │   └── models.go         — SyncUser, SyncServer, wire formats
│   ├── vpn/
│   │   ├── engine.go         — SingboxEngine, config generation
│   │   ├── singbox.go        — JSON config structs (серверный конфиг)
│   │   ├── clientconfig.go   — Генерация iOS конфига
│   │   └── userapi.go        — HTTP клиент к User API (port 15380)
│   ├── db/
│   │   ├── models.go         — User, VPNServer, Admin, TrafficSnapshot
│   │   ├── users.go          — CRUD + upsert users
│   │   ├── servers.go        — CRUD + upsert servers
│   │   └── ...               — traffic, admin, settings
│   ├── auth/
│   │   ├── jwt.go            — JWT create/verify, refresh blacklist
│   │   ├── middleware.go     — RequireAuth, CookieOrBearerAuth
│   │   ├── apple.go          — Apple identity token verifier
│   │   └── password.go       — Argon2id (+ legacy bcrypt/SHA256)
│   ├── config/config.go      — YAML loader, env var substitution, validation
│   └── monitoring/           — Traffic collector (Clash API polling)
├── migrations/
│   ├── init.sql              — Все таблицы (идемпотентный)
│   └── 002_reality_private_key.sql — ALTER TABLE для Reality ключей
├── scripts/                  — Операционные скрипты (см. раздел 12)
├── docker-compose.yml        — postgres, redis, chameleon, nginx
├── Dockerfile                — Multi-stage Go build (для DE)
├── Dockerfile.prebuilt       — Использует готовый бинарник (для NL)
├── config.production.yaml    — Шаблон конфига (deploy.sh подставляет значения)
├── config.yaml               — Продакшн конфиг (генерируется deploy.sh, в .gitignore)
└── deploy.sh                 — Деплой скрипт (локальный)
```

### Порядок инициализации (main.go)

```
1. CLI flag parsing     — обработка подкоманд (admin create, etc.)
2. Config loading       — YAML → env var substitution → validate
3. Logger              — zap (JSON prod / colorized dev)
4. PostgreSQL           — connection pool (min_conns=5, max_conns=25)
5. Redis               — connect + ping
6. JWT Manager         — load secret, configure TTLs
7. Apple Verifier      — Apple identity token verifier
8. VPN Engine          — SingboxEngine
   ├── Reality keys    — из DB (vpn_servers) или fallback env vars
   └── SNI            — из DB или config
9. VPN Users           — загрузка активных пользователей из DB
10. Traffic Collector  — background goroutine, каждые 60s → Clash API
11. Cluster Syncer     — init pub/sub + HTTP reconciler
12. HTTP Server        — регистрация роутов, middleware
13. cluster.Start()    — запуск pub/sub subscriber + reconcile loop
14. Graceful shutdown  — SIGINT/SIGTERM → 10s drain
```

### HTTP API — полная таблица роутов

#### Mobile API (`/api/mobile`, `/api/v1/mobile`)

| Метод | Путь | Auth | Описание |
|---|---|---|---|
| POST | `/auth/register` | — | Регистрация по device_id |
| POST | `/auth/apple` | — | Авторизация через Apple Sign-In |
| POST | `/auth/refresh` | — | Обновление JWT (single-use refresh token) |
| POST | `/auth/logout` | — | Логаут |
| POST | `/subscription/verify` | JWT | Верификация App Store покупки |
| GET | `/config` | `?username=` | Скачать sing-box конфиг для iOS |

#### Subscription Link
| Метод | Путь | Auth | Описание |
|---|---|---|---|
| GET | `/sub/:token/:mode` | token | Конфиг по subscription token (QR/ссылка) |

#### Admin API (`/api/v1/admin`, `/api/admin`)

| Метод | Путь | Описание |
|---|---|---|
| POST | `/auth/login` | Логин (JWT + httpOnly cookie) |
| POST | `/auth/refresh` | Обновление токена |
| POST | `/auth/logout` | Логаут |
| GET | `/auth/me` | Текущий admin |
| GET | `/users` | Список пользователей (пагинация) |
| GET | `/users/:id` | Пользователь по ID |
| DELETE | `/users/:id` | Мягкое удаление |
| POST | `/users/:id/extend` | Продлить подписку |
| POST | `/nodes/sync` | Перезагрузить VPN конфиг |
| POST | `/nodes/restart-singbox` | SIGHUP в sing-box |
| GET | `/nodes` | Статус всех нод кластера |
| GET | `/stats` | Базовая статистика |
| GET | `/stats/dashboard` | Полный дашборд (local + peers) |
| GET | `/servers` | Список VPN серверов |
| POST | `/servers` | Создать сервер |
| PUT | `/servers/:id` | Обновить сервер |
| DELETE | `/servers/:id` | Удалить сервер |
| GET | `/admins` | Список admin users |
| POST | `/admins` | Создать admin user |
| DELETE | `/admins/:id` | Удалить admin user |

#### Cluster API (`/api/cluster`) — только между нодами

| Метод | Путь | Auth | Описание |
|---|---|---|---|
| GET | `/pull?since=<RFC3339>` | Bearer (cluster secret) | Получить изменения с timestamp |
| POST | `/push` | Bearer (cluster secret) | Отправить изменения на пиров |

#### System
| Метод | Путь | Описание |
|---|---|---|
| GET | `/health` | `{"status":"ok","version":"dev"}` |

### Middleware Stack (порядок применения)

```
1. Recovery           — перехват паник, логирование stack trace
2. Request ID         — X-Request-Id (генерация или propagation)
3. Structured Logger  — zap: method, path, status, latency, ip
4. Security Headers   — HSTS, CSP, X-Frame-Options, etc.
5. CORS               — cors_origins из config (для SPA)
6. Timeout            — abort после 30 секунд
7. Rate Limiting      — sliding window: 60/min mobile, 120/min admin
```

### Конфигурация (config.yaml)

```yaml
server:
  host: "0.0.0.0"
  port: 8000
  cors_origins: [...]

database:
  url: "${DATABASE_URL}"       # postgres://user:pass@host/db
  max_conns: 25
  min_conns: 5
  max_conn_lifetime: "1h"

redis:
  url: "${REDIS_URL}"          # redis://:pass@host:6379/0

auth:
  jwt_secret: "${JWT_SECRET}"  # min 32 chars
  jwt_access_ttl: "24h"
  jwt_refresh_ttl: "720h"
  apple_bundle_id: "com.chameleonvpn.app"

vpn:
  listen_port: 2096
  client_mtu: 1400
  dns_remote: "https://1.1.1.1/dns-query"
  dns_direct: "https://8.8.8.8/dns-query"
  urltest_interval: "3m"
  clash_api_port: 9090
  user_api_port: 15380
  user_api_secret: "${USER_API_SECRET}"
  reality:
    private_key: "${REALITY_PRIVATE_KEY}"  # fallback, основное — DB
    public_key: "${REALITY_PUBLIC_KEY}"
    short_ids: ["", "0018e1ec", ...]
    snis:
      default: "ads.adfox.ru"

cluster:
  enabled: true
  node_id: "de-1"              # задаётся deploy.sh
  secret: "${CLUSTER_SECRET}"  # min 32 chars, shared между нодами
  sync_interval: "30s"
  reconcile_interval: "5m"
  pubsub_channel: "chameleon:sync"
  peers:                       # задаётся deploy.sh
    - id: "nl-1"
      url: "http://194.135.38.90:8000"

rate_limit:
  mobile_per_minute: 60
  admin_per_minute: 120
```

---

## 5. VPN Engine (sing-box)

### Архитектура

```
chameleon (backend)
    │
    ├── SingboxEngine (ModeDocker)
    │     │
    │     ├── buildServerConfig() → singbox-config.json
    │     │     ├── VLESS Reality inbound (port 2096)
    │     │     │     └── Users: [{name, uuid, flow}]
    │     │     ├── Direct outbound
    │     │     ├── Clash API (127.0.0.1:9090)
    │     │     └── User API service (127.0.0.1:15380)
    │     │
    │     ├── Write config → /etc/singbox/singbox-config.json (docker volume)
    │     │
    │     └── Signal: docker kill -s HUP singbox
    │
    └── UserAPIClient (port 15380)
          ├── AddUser()     → POST /api/v1/inbounds/vless-reality-tcp/users
          ├── RemoveUser()  → DELETE /api/v1/inbounds/vless-reality-tcp/users/{name}
          └── ReplaceUsers() → PUT /api/v1/inbounds/vless-reality-tcp/users
```

### sing-box-fork (серверный)

**Образ:** `sing-box-fork:v1.13.6-userapi`  
**Отличие от стандартного:** добавлен REST API на порту 15380 для управления пользователями без перезапуска.

**Запуск:** standalone контейнер (НЕ в docker-compose)
```bash
docker run -d \
  --name singbox \
  --restart unless-stopped \
  --network host \
  --cap-add NET_ADMIN \
  --cap-add NET_BIND_SERVICE \
  -v chameleon-singbox-config:/etc/singbox:ro \
  sing-box-fork:v1.13.6-userapi \
  run -c /etc/singbox/singbox-config.json
```

### Серверный конфиг (генерируется chameleon)

```json
{
  "inbounds": [{
    "type": "vless",
    "tag": "vless-reality-tcp",
    "listen": "0.0.0.0",
    "listen_port": 2096,
    "users": [
      {"name": "vpn_username", "uuid": "36-char-uuid", "flow": "xtls-rprx-vision"}
    ],
    "tls": {
      "enabled": true,
      "server_name": "ads.adfox.ru",
      "reality": {
        "enabled": true,
        "handshake": {"server": "ads.adfox.ru", "server_port": 443},
        "private_key": "<server_private_key>",
        "short_id": ["", "0018e1ec", ...]
      }
    }
  }],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "dns", "tag": "dns-out"}
  ],
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "secret": ""
    }
  }
}
```

### User API (zero-downtime)

**Base URL:** `http://127.0.0.1:15380`  
**Auth:** `Authorization: Bearer ${USER_API_SECRET}`

```
GET  /api/v1/inbounds                          — список inbounds
GET  /api/v1/inbounds/{tag}/users              — список пользователей
POST /api/v1/inbounds/{tag}/users              — добавить пользователя
PUT  /api/v1/inbounds/{tag}/users              — заменить всех пользователей
DELETE /api/v1/inbounds/{tag}/users/{name}     — удалить пользователя
```

**Логика fallback:**
- Сначала пробует User API
- Если недоступен → SIGHUP (конфиг перезаписывается, reload с минимальным downtime)

### Клиентский конфиг (iOS, генерируется chameleon)

```json
{
  "inbounds": [{
    "type": "tun",
    "interface_name": "utun",
    "inet4_range": "172.19.0.1/30",
    "mtu": 1400,
    "stack": "system",
    "auto_route": true
  }],
  "outbounds": [
    {
      "type": "selector",
      "tag": "Proxy",
      "outbounds": ["Auto", "🇩🇪 Germany", "🇳🇱 Netherlands", "🇷🇺 Russia→DE", "🇷🇺 Russia→NL", "direct"]
    },
    {
      "type": "urltest",
      "tag": "Auto",
      "outbounds": ["🇩🇪 Germany", "🇳🇱 Netherlands"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m",
      "tolerance": 100
    },
    {
      "type": "vless",
      "tag": "🇩🇪 Germany",
      "server": "162.19.242.30",
      "server_port": 2096,
      "uuid": "<user_uuid>",
      "flow": "xtls-rprx-vision",
      "packet_encoding": "xudp",
      "tls": {
        "enabled": true,
        "server_name": "ads.adfox.ru",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {
          "enabled": true,
          "public_key": "<server_public_key>"
        }
      }
    }
    // ... аналогично для NL, relay серверов
  ],
  "dns": {
    "servers": [
      {"type": "fakeip", "tag": "fakeip"},
      {"address": "https://1.1.1.1/dns-query", "tag": "remote"},
      {"address": "https://8.8.8.8/dns-query", "tag": "direct-dns", "detour": "direct"}
    ],
    "fakeip": {"enabled": true, "inet4_range": "198.18.0.0/15"}
  },
  "route": {
    "rules": [
      {"action": "sniff"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"clash_mode": "Direct", "outbound": "direct"},
      {"protocol": "quic", "network": "udp", "port": 443, "action": "reject", "no_drop": true},
      {"ip_is_private": true, "outbound": "direct"}
    ],
    "final": "Proxy"
  }
}
```

### Ключевые факты sing-box 1.13

| Правило | Почему |
|---|---|
| `sniff` ДОЛЖЕН быть первым route rule | Иначе protocol detection не работает → DNS loop |
| `hijack-dns` (через дефис) | В 1.11+ именно такое написание |
| Нет `detour: "direct"` у DNS серверов | В 1.13 серверы идут напрямую по умолчанию |
| `stack: "system"` | Единственный рабочий вариант для iOS NetworkExtension |
| `no_drop: true` в QUIC reject | Без него iOS зависает на некоторых сайтах |
| `short_id: ""` | Пустой всегда валиден. Случайный → "reality verification failed" |

---

## 6. Cluster Mesh Sync

### Архитектура

```
DE (node: de-1)                    NL (node: nl-1)
┌────────────────────┐             ┌────────────────────┐
│ chameleon backend  │◄────────────┤ chameleon backend  │
│                    │  HTTP pull  │                    │
│ PostgreSQL         │────────────►│ PostgreSQL         │
│                    │  HTTP push  │                    │
│ Redis              │◄───────────►│ Redis              │
│  pub/sub channel   │  pub/sub    │  pub/sub channel   │
└────────────────────┘             └────────────────────┘
```

Каждая нода **автономна**. Sync — дополнительный уровень надёжности, не обязательный.

### Два механизма синхронизации

#### 1. Real-time: Redis Pub/Sub

```
Событие (создание/обновление user)
  │
  └──► Publisher.Publish(SyncUser) → Redis channel "chameleon:sync"
         │
         └──► Все ноды-подписчики получают событие
               │
               └──► db.UpsertUserByVPNUUID() → reload VPN engine
```

- Канал: `chameleon:sync`
- Payload: JSON `SyncUser` с полями пользователя
- Каждая нода фильтрует свои же события (node_id в payload)
- Если Redis недоступен → работает HTTP fallback

#### 2. Периодический: HTTP Pull/Push (5 мин)

```
reconcileLoop() каждые 5 мин:
  для каждого peer:
    1. Pull: GET peer/api/cluster/pull?since=<last_sync_time>
       ← PullResponse{NodeID, Users[], Servers[]}
       → UpsertUserByVPNUUID() для каждого
       → UpsertServerByKey() для каждого сервера

    2. Push: POST peer/api/cluster/push
       → PushRequest{NodeID, Users[], Servers[]}
       ← PushResponse{Received, Applied}

    3. Если были изменения → reload VPN engine
```

**Разрешение конфликтов:** побеждает запись с более поздним `updated_at`.

### Конфигурация кластера

```yaml
cluster:
  enabled: true
  node_id: "de-1"          # уникальный ID ноды
  secret: "${CLUSTER_SECRET}"  # shared secret, min 32 chars
  sync_interval: "30s"     # интервал pub/sub keepalive
  reconcile_interval: "5m" # HTTP reconciliation
  pubsub_channel: "chameleon:sync"
  peers:
    - id: "nl-1"
      url: "http://194.135.38.90:8000"
```

### Wire форматы

```go
// SyncUser — что синхронизируется между нодами
type SyncUser struct {
    VPNUUID            *string
    VPNUsername        *string
    IsActive           bool
    SubscriptionExpiry *time.Time
    CurrentPlan        *string
    DeviceLimit        int
    UpdatedAt          time.Time
}

// SyncServer — что синхронизируется по серверам
type SyncServer struct {
    Key              string
    Name, Flag       string
    Host             string
    Port             int
    SNI              string
    RealityPublicKey string
    // НЕ включает private_key (безопасность)
    IsActive         bool
    UpdatedAt        time.Time
}
```

### Auth кластерных эндпоинтов

Все `/api/cluster/*` запросы проверяют:
```
Authorization: Bearer <CLUSTER_SECRET>
```
Если секрет отсутствует → 401 "missing authorization"  
Если секрет неверный → 403 "invalid cluster secret"

---

## 7. База данных

### Схема таблиц

#### `users` — VPN пользователи

```sql
id                    SERIAL PRIMARY KEY
telegram_id           BIGINT
username              VARCHAR(255)
full_name             VARCHAR(255)
is_active             BOOLEAN DEFAULT true
subscription_expiry   TIMESTAMPTZ
vpn_username          VARCHAR(255) UNIQUE  -- sing-box username, "device_<hash>"
vpn_uuid              VARCHAR(255) UNIQUE  -- UUID v4, идентификатор в sing-box
vpn_short_id          VARCHAR(255)         -- Reality short_id (обычно "")
auth_provider         VARCHAR(50)          -- "device", "apple", "google"
apple_id              VARCHAR(255)
device_id             VARCHAR(255)
original_transaction_id VARCHAR(255) UNIQUE -- App Store
app_store_product_id  VARCHAR(255)
subscription_token    VARCHAR(255) UNIQUE  -- для /sub/:token/... ссылок
activation_code       VARCHAR(255) UNIQUE
current_plan          VARCHAR(50)          -- "trial", "monthly", "yearly"
cumulative_traffic    BIGINT DEFAULT 0
device_limit          INTEGER DEFAULT 1
notified_3d           BOOLEAN DEFAULT false
notified_1d           BOOLEAN DEFAULT false
created_at            TIMESTAMPTZ DEFAULT NOW()
updated_at            TIMESTAMPTZ DEFAULT NOW()  -- auto-updated via trigger
```

**Генерация VPN credentials:**
- `vpn_username` = `"device_" + hex(sha256(device_id))[:8]`
- `vpn_uuid` = UUID v4 (random)
- `vpn_short_id` = `""` (пустой — всегда валиден в Reality)

#### `vpn_servers` — VPN ноды

```sql
id                    SERIAL PRIMARY KEY
key                   VARCHAR(50) UNIQUE   -- "de", "nl", "relay-de"
name                  VARCHAR(255)         -- "🇩🇪 Germany"
flag                  VARCHAR(10)
host                  VARCHAR(255)         -- IP адрес
port                  INTEGER
domain                VARCHAR(255)
sni                   VARCHAR(255)         -- Reality SNI
reality_public_key    VARCHAR(255)         -- публичный ключ (в клиентский конфиг)
reality_private_key   VARCHAR(255)         -- приватный ключ (только сервер!)
is_active             BOOLEAN DEFAULT true
sort_order            INTEGER DEFAULT 0
provider_name         VARCHAR(255)         -- "OVH", "Timeweb"
cost_monthly          DECIMAL(10,2)
provider_url          VARCHAR(500)
provider_login        VARCHAR(255)
provider_password     VARCHAR(255)         -- зашифровано или в plaintext
notes                 TEXT
created_at            TIMESTAMPTZ
updated_at            TIMESTAMPTZ
```

**Важно:** `reality_private_key` хранится в БД, читается при старте chameleon. Это единственный источник правды — нет `.env` файлов с ключами.

#### `admin_users`

```sql
id            SERIAL PRIMARY KEY
username      VARCHAR(255) UNIQUE
password_hash TEXT          -- Argon2id (legacy: bcrypt, SHA256)
role          VARCHAR(50)   -- "admin", "operator", "viewer"
is_active     BOOLEAN
last_login    TIMESTAMPTZ
created_at    TIMESTAMPTZ
```

#### `traffic_snapshots`

```sql
id               SERIAL PRIMARY KEY
vpn_username     VARCHAR(255)
used_traffic     BIGINT        -- total bytes
download_traffic BIGINT
upload_traffic   BIGINT
timestamp        TIMESTAMPTZ
```

Собирается каждые 60 сек через Clash API polling.

#### `node_metrics_history`

```sql
id           SERIAL PRIMARY KEY
node_key     VARCHAR(50)
cpu          REAL           -- %
ram_used     REAL           -- bytes
ram_total    REAL
disk         REAL           -- %
traffic_up   BIGINT
traffic_down BIGINT
online_users INTEGER
recorded_at  TIMESTAMPTZ
```

#### `app_settings` — key-value

```sql
key   VARCHAR(255) UNIQUE
value TEXT
```

#### `cluster_peers`, `admin_audit_log` — для расширения

### Миграции

```
migrations/
├── init.sql                   — всё (CREATE TABLE IF NOT EXISTS, идемпотентный)
└── 002_reality_private_key.sql — ALTER TABLE vpn_servers ADD COLUMN reality_*
```

Deploy.sh применяет `002_*.sql` при каждом деплое (безопасно, идемпотентно).

### Ключевые индексы

```sql
UNIQUE INDEX ON users(vpn_username)
UNIQUE INDEX ON users(vpn_uuid)
UNIQUE INDEX ON users(subscription_token)
INDEX ON users(apple_id)
INDEX ON users(device_id)
INDEX ON users(is_active, subscription_expiry)  -- для поиска активных
INDEX ON traffic_snapshots(vpn_username, timestamp)
```

---

## 8. Аутентификация

### Mobile API — JWT

**Flow:**
```
POST /auth/register {device_id}
  → создать/найти user по device_id
  → сгенерировать VPN credentials если новый
  → CreateTokenPair() → {access_token, refresh_token}

POST /auth/apple {identity_token}
  → верифицировать Apple JWT (публичный ключ Apple)
  → создать/найти user по apple_id
  → CreateTokenPair()
```

**Tokens:**
- **Access token**: 24h, claims: `user_id`, `username`, `role`
- **Refresh token**: 30 дней, single-use (после использования → Redis blacklist)

**JWT подпись:** HMAC-SHA256, secret min 32 chars

### Admin API — JWT + Cookie

```
POST /auth/login {username, password}
  → проверить bcrypt/Argon2id hash
  → CreateTokenPair()
  → Set-Cookie: access_token=...; HttpOnly; Secure; SameSite=Strict
  → Response: {access_token, refresh_token}
```

Middleware `CookieOrBearerAuth` — поддерживает оба способа:
- `Authorization: Bearer <token>`
- Cookie `access_token`

### Кластерная Auth

```
Authorization: Bearer <CLUSTER_SECRET>
```
Constant-time compare (защита от timing attacks).

---

## 9. iOS + macOS приложения

iOS и macOS живут в **одном Xcode-проекте** и делят SwiftUI/модели. На каждый платформу — отдельный App Store listing (не Universal Purchase).

| Target | Type | Platform | Bundle ID | App Store ID |
|---|---|---|---|---|
| `Chameleon` | application | iOS 17+ | `com.madfrog.vpn` | 6761008632 |
| `PacketTunnel` | app-extension | iOS 17+ | `com.madfrog.vpn.tunnel` | — |
| `ChameleonMac` | application | macOS 14+ | `com.madfrog.vpn.mac` | 6762887787 |
| `PacketTunnelMac` | app-extension | macOS 14+ | `com.madfrog.vpn.mac.tunnel` | — |

App Group один на обе платформы: `group.com.madfrog.vpn`.

### Структура

```
clients/apple/
├── ChameleonVPN/               — основной SwiftUI код (iOS + macOS)
│   ├── Models/
│   │   ├── VPNManager.swift    — NEVPNManager обёртка
│   │   ├── AppState.swift      — глобальное состояние, retry логика
│   │   ├── APIClient.swift     — HTTP клиент к backend API
│   │   ├── CommandClient.swift — gRPC/stats клиент
│   │   └── PlatformMainApp.swift — PlatformPasteboard, PlatformURLOpener (main-app only)
│   └── Views/
│       ├── MainView.swift      — главный экран (iOS + macOS)
│       ├── MenuBarContent.swift — macOS tray popover
│       ├── DebugLogsView.swift — просмотр логов
│       └── SettingsView.swift  — настройки
├── ChameleonMac/               — Info.plist + entitlements для macOS main app
├── PacketTunnel/               — iOS VPN Extension
│   ├── ExtensionProvider.swift — NEPacketTunnelProvider, startTunnel/stopTunnel
│   └── ExtensionPlatformInterface.swift — bridge sing-box ↔ NetworkExtension
├── PacketTunnelMac/            — Info.plist + entitlements для macOS NE extension
├── Shared/                     — общий код для всех targets
│   ├── ConfigSanitizer.swift
│   ├── Constants.swift
│   ├── Logger.swift
│   ├── PlatformDevice.swift    — identifier, systemVersion (extension-safe)
│   └── PlatformViewExtensions.swift — cross-platform SwiftUI modifiers
├── Frameworks/
│   └── Libbox.xcframework      — sing-box 1.13.5 (ios + ios-sim + macos), git-ignored
└── project.yml                 — XcodeGen spec для всех 4 targets
```

### Libbox.xcframework
Git-ignored (~494 MB). Собирается из [sing-box v1.13.5](https://github.com/SagerNet/sing-box) через `make lib_apple` с sagernet/gomobile fork. tvOS slices срезаются. Info.plist каждого slice патчится для App Store валидации. Инструкция: `docs/` memory `reference_libbox_build.md`.

### Signing (macOS App Store distribution)
- Distribution cert: `3rd Party Mac Developer Application` (в keychain)
- Installer cert: `3rd Party Mac Developer Installer`
- Provisioning profiles (MAC_APP_STORE): `MadFrog Mac App Store 2`, `MadFrog Mac Tunnel App Store 2`
- App Group `group.com.madfrog.vpn` привязывается к Bundle IDs через **Xcode Organizer Distribute UI** (ASC API этого не умеет)

### Релиз Mac build в TestFlight
Команда:
```bash
xcodebuild -project clients/apple/MadFrogVPN.xcodeproj -scheme MadFrogVPNMac -configuration Release \
  -destination 'generic/platform=macOS' -archivePath clients/apple/build/MadFrogVPNMac.xcarchive archive
open -a Xcode clients/apple/build/MadFrogVPNMac.xcarchive
# В Organizer: Distribute App → App Store Connect → Upload → Automatic signing
```

Для первого build также нужно в App Store Connect вручную:
- Создать app listing (`macOS` platform, bundle `com.madfrog.vpn.mac`)
- Добавить beta localization (ru) с description
- Установить `contentRightsDeclaration = DOES_NOT_USE_THIRD_PARTY_CONTENT`

Подробнее про TestFlight gating: memory `feedback_mac_testflight_gotchas.md`.

### Сценарии загрузки конфига

| Событие | Поведение |
|---|---|
| Запуск приложения | `initialize()` → `silentConfigUpdate()` (ждёт завершения) |
| Возврат из фона | `scenePhase .active` → `handleForeground()` → фоновый refresh |
| Нажатие Connect | `refreshConfig(timeout: 5s)` → коннект со свежим (или кешем при таймауте) |
| Отключение VPN | `Task { silentConfigUpdate() }` — фоновый refresh для следующего подключения |
| Смена сервера | reconnect с новым selector |

`silentConfigUpdate()` никогда не показывает ошибку пользователю — только лог.  
`refreshConfig(timeout:)` — гонка fetch vs таймер; кеш используется если сеть недоступна или медленная.

### VPN Connection Flow

```
1. User tap "Connect"
2. AppState.toggleVPN()
3. refreshConfig(timeout: 5s) — fetch fresh config или таймаут
4. buildConfigWithSelector(tag) — применить выбранный сервер
5. VPNManager.connect(configJSON:)
6. ExtensionProvider.startTunnel()
   ├── Создать BoxService (libbox)
   ├── Загрузить конфиг
   └── Start VPN
7. Ждать NEVPNStatus.connected (timeout 30s)
8. Если timeout → disconnect + показать ошибку
```

### Выбор сервера

```swift
selectServer(outboundTag: String)
  → изменить selector "default" в config JSON
  → сохранить в UserDefaults
  → disconnect() → reconnect()
```

Источники конфига (приоритет):
1. Tunnel options (при явном подключении)
2. UserDefaults (при on-demand)
3. Файл (fallback)

### Константы (Constants.swift)

```swift
struct AppConfig {
    static let apiBaseURL = "https://razblokirator.ru"
    static let bundleID = "com.chameleonvpn.app"
    static let tunnelBundleID = "com.chameleonvpn.app.PacketTunnel"
}
```

### Известные ограничения iOS

| Проблема | Решение |
|---|---|
| `stack: "mixed"` не работает | Используем `stack: "system"` |
| `stack: "gvisor"` медленный на DE | Только `system` |
| QUIC зависание | Block UDP 443, `no_drop: true` |
| PacketTunnel — отдельный процесс | Логи через shared UserDefaults или Group Container |

---

## 10. Admin SPA

### Стек

```
React 19
TailwindCSS 4
shadcn/ui
TanStack Router (file-based routing)
TanStack Query (server state)
Vite 7
```

### Build и деплой

```
clients/admin/
├── Dockerfile        — nginx:alpine + npm build
├── nginx.conf        → копируется в chameleon-nginx контейнер
└── src/
    ├── routes/       — страницы (users, nodes, servers, stats)
    └── components/   — shadcn/ui компоненты
```

Admin SPA собирается в Docker образ `chameleon-nginx` и раздаётся через nginx.  
Nginx проксирует `/api/*` → `localhost:8000` (chameleon).

---

## 11. Deploy

### deploy.sh

```bash
./deploy.sh de              # деплой только chameleon (singbox не трогается!)
./deploy.sh nl              # то же для NL
./deploy.sh all             # оба сервера последовательно
./deploy.sh de --with-singbox  # + перезапуск singbox (кратковременный VPN drop)
```

### Что делает deploy.sh

```
[локально]
1. Cross-compile для NL (NL_PREBUILT=1, OOM на 2GB RAM)
   CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build ./cmd/chameleon

2. rsync проекта на сервер (без .git, .env, config.yaml, target/)
   ВАЖНО: chameleon-linux НЕ исключается (NL нужен свежий бинарник)

[на сервере через SSH]
3. cp config.production.yaml config.yaml
   sed: подставить node_id, SNI
   sed: подставить peers (DE→[NL], NL→[DE])

4. Записать .env:
   DATABASE_URL, REDIS_URL, JWT_SECRET,
   USER_API_SECRET, CLUSTER_SECRET

5. sudo tee /etc/chameleon-alerts.env (Telegram bot token + chat IDs)
   chmod 644 (читается скриптами от ubuntu)

6. Применить DB миграции (002_*.sql)

7. docker volume create (идемпотентно)

8. DE:  docker compose build chameleon (из исходников)
   NL:  docker build -f Dockerfile.prebuilt . (из бинарника)

9. docker compose up -d --no-deps chameleon
   (--no-deps: НЕ трогать singbox, postgres, redis!)

10. Ждать /health (до 90 сек)

11. Создать admin user (идемпотентно)

12. Если --with-singbox: ./scripts/singbox-run.sh --force

13. Установить cron:
    * * * * * singbox-watchdog.sh
    * * * * * health-check.sh
    0 3 * * * db-backup.sh

14. Post-deploy проверки:
    ✓ Chameleon API /health
    ✓ Singbox container running
    ✓ User API :15380
    ✓ VPN port 2096
    ✓ Clash API :9090
```

### .env на сервере

```bash
# /home/ubuntu/chameleon/backend/.env  (chmod 600)
DB_PASSWORD=...
REDIS_PASSWORD=...
JWT_SECRET=...
USER_API_SECRET=...
CLUSTER_SECRET=...
```

### Почему --no-deps обязателен

`docker compose up -d chameleon` поднял бы все зависимости, включая пересоздание сетей → singbox потерял бы сеть → VPN упал. `--no-deps` поднимает только один сервис.

### Добавление новой ноды

1. Поднять сервер (Ubuntu 22+)
2. Установить Docker
3. Добавить в deploy.sh в `get_node_config()`:
   ```bash
   newnode)
     NODE_SSH="user@ip"
     NODE_DIR="/home/user/chameleon"
     NODE_NODE_ID="newnode-1"
     NODE_SNI="ads.adfox.ru"
     NODE_PREBUILT=1  # если мало RAM
   ```
4. Добавить в peers всех существующих нод и у новой ноды:
   ```yaml
   peers:
     - id: "de-1"
       url: "http://162.19.242.30:8000"
     - id: "nl-1"
       url: "http://194.135.38.90:8000"
   ```
5. `./deploy.sh newnode`
6. На новой ноде: `./scripts/singbox-run.sh`
7. Добавить Reality ключи в `vpn_servers` таблицу
8. Добавить сервер в `vpn_servers` (он синхронизируется на все ноды)

---

## 12. Scripts и Cron

### singbox-run.sh

Запускает sing-box как standalone контейнер:
```bash
docker rm -f singbox 2>/dev/null || true
docker run -d \
  --name singbox \
  --restart unless-stopped \
  --network host \
  --cap-add NET_ADMIN \
  -v chameleon-singbox-config:/etc/singbox:ro \
  sing-box-fork:v1.13.6-userapi \
  run -c /etc/singbox/singbox-config.json
```
Вызывается при первом деплое или `--with-singbox`.

### singbox-watchdog.sh (cron: каждую минуту)

```
1. Проверить: docker ps | grep singbox → running?
2. Если НЕ running:
   a. docker rm -f singbox
   b. sudo test -f <config_path>  (нужен sudo, ubuntu не может читать /var/lib/docker/)
   c. Если конфиг есть → docker run ... (те же параметры что singbox-run.sh)
   d. Ждать 3 секунды → проверить запустился ли
   e. Telegram alert: "singbox was down, watchdog restarted it"
      или "singbox FAILED to start!"
```

Log: `/var/log/singbox-watchdog.log`

### health-check.sh (cron: каждую минуту)

Проверяет `/health` backend. Отправляет Telegram alert если недоступен.  
Rate limiting: 1 алерт / 5 мин на проблему.

Log: `/var/log/chameleon-health.log`

### db-backup.sh (cron: 3:00 AM ежедневно)

```bash
pg_dump chameleon | gzip > /backup/chameleon_YYYYMMDD.sql.gz
find /backup -name "*.sql.gz" -mtime +7 -delete  # 7-day retention
```
Алерт в Telegram при ошибке.

### telegram-alert.sh

```bash
./telegram-alert.sh "🟡 <b>hostname</b>: singbox was down"
```
Читает `/etc/chameleon-alerts.env` (BOT_TOKEN + CHAT_IDS).  
Отправляет в каждый chat_id из списка.

### Установленный Cron (на каждой ноде)

```
* * * * * /path/singbox-watchdog.sh >> /var/log/singbox-watchdog.log 2>&1
* * * * * /path/health-check.sh >> /var/log/chameleon-health.log 2>&1
0 3 * * * /path/db-backup.sh >> /var/log/chameleon-backup.log 2>&1
```

---

## 13. Критические правила

### VPN протокол

1. **SNI: `ads.adfox.ru`** — проверен, не блокируется РКН. НИКОГДА не использовать google.com/cloudflare.com
2. **short_id: `""`** — пустой всегда валиден. Случайные short_ids → "reality verification failed"
3. **sing-box route rules ORDER**: `sniff` ПЕРВЫЙ, потом `hijack-dns`
4. **DNS detour**: НЕ нужен в sing-box 1.13 — серверы идут напрямую по умолчанию
5. **Перед любым deploy singbox конфига**: `sing-box check -c config.json` на сервере

### Операции

6. **НИКОГДА** `docker compose down --remove-orphans` — убьёт standalone singbox
7. **ВСЕГДА** `--no-deps` при перезапуске chameleon — иначе убьёт singbox через сеть
8. **Reality ключи** менять только в БД (`vpn_servers`), потом restart chameleon, потом restart singbox
9. **NL деплой** — бинарник cross-compile на маке, rsync на сервер (Dockerfile.prebuilt использует его)
10. **Cluster secret** — должен быть в `.env` И в `docker-compose.yml` environment И одинаковый на всех нодах

### Несовместимости

| Комбинация | Проблема |
|---|---|
| Xray v26 + sing-box 1.13 клиент | НЕСОВМЕСТИМЫ. Используй Xray 25.12.8 |
| sing-box mux (h2mux) + Xray сервер | НЕСОВМЕСТИМЫ |
| `stack: "mixed"` на iOS | Трафик не идёт |
| UDP 443 без reject | iOS зависает на QUIC |
| Random short_id клиента | reality verification failed |

---

## 14. Диагностика

### Быстрые проверки

```bash
# SSH
ssh ubuntu@162.19.242.30   # DE
ssh root@194.135.38.90     # NL

# Backend health
curl http://localhost:8000/health

# Singbox running?
docker ps | grep singbox
docker logs singbox --tail 20

# VPN port listening?
ss -tlnp | grep 2096

# User API работает?
curl -s -H "Authorization: Bearer $USER_API_SECRET" \
  http://127.0.0.1:15380/api/v1/inbounds

# Clash API (трафик, подключения)
curl -s http://127.0.0.1:9090/connections
curl -s http://127.0.0.1:9090/traffic

# Cluster sync лог
docker logs chameleon 2>&1 | grep cluster | tail -20

# Watchdog лог
tail -f /var/log/singbox-watchdog.log

# Health check лог
tail -f /var/log/chameleon-health.log
```

### Restart singbox (без потери других соединений)

```bash
cd ~/chameleon/backend
./scripts/singbox-run.sh --force
```

### Reload пользователей без restart

```bash
# Через Admin API
curl -X POST http://localhost:8000/api/v1/clients/admin/nodes/sync \
  -H "Authorization: Bearer <admin_token>"
```

### Проверить конфиг singbox до деплоя

```bash
sing-box check -c /etc/singbox/singbox-config.json
```

### iOS отладка

1. Ladybug icon в приложении → Copy logs → вставить в Claude
2. Или: Xcode → Devices → просмотр логов PacketTunnel extension

### Если cluster sync не работает

```bash
# Проверить что CLUSTER_SECRET одинаковый на обоих нодах
docker inspect chameleon --format '{{range .Config.Env}}{{println .}}{{end}}' | grep CLUSTER

# Тест pull вручную (с DE, проверяем NL)
curl -H "Authorization: Bearer $CLUSTER_SECRET" \
  http://194.135.38.90:8000/api/cluster/pull

# Логи reconciliation
docker logs chameleon 2>&1 | grep -E 'reconcil|cluster|peer'
```

---

## 15. История решённых проблем

### 2026-04-10: iOS config refresh improvements

- **Connect**: теперь сначала fetch свежего конфига (≤5с timeout), потом коннект — раньше коннектился с кешем
- **Disconnect**: фоновый refresh конфига для следующего подключения
- **Foreground**: при возврате приложения из фона — фоновый refresh (`scenePhase .active`)
- **silentConfigUpdate()**: исправлен баг — больше не показывает toast ошибки пользователю при сетевой ошибке
- **refreshConfig(timeout:)**: гонка fetch vs таймер — кеш используется если сеть недоступна
- **hasInitialized**: флаг для предотвращения двойного refresh при запуске (`.active` тоже стреляет)

### 2026-04-10: Cluster sync enabled + fixes

- **Cluster mesh sync включён** на DE+NL. Подтверждено: pull/push работает
- **CLUSTER_SECRET** добавлен в docker-compose.yml env (не было → container падал)
- **NL бинарник**: убрал `chameleon-linux` из rsync exclude → NL получает свежий бинарник каждый деплой (был Docker cache → старый код)
- **Watchdog**: `sudo test -f` для проверки конфига (ubuntu не читает `/var/lib/docker/volumes/` без sudo)
- **alerts.env**: chmod 644 вместо 600 (ubuntu/скрипты должны читать)
- **Telegram алерты**: проверены, приходят при падении singbox

### 2026-04-10: Infrastructure stabilization

- **sing-box вынесен из compose** → standalone контейнер, compose операции не убивают VPN
- **Reality ключи в БД** → единственный источник правды
- **Cluster auth**: shared secret (Bearer) на /api/cluster/*
- **Server mesh sync**: vpn_servers синхронизируются между нодами
- **Telegram алерты**: watchdog + health-check
- **DB backups**: pg_dump ежедневно в 3:00, 7 дней retention
- **Deploy script**: ./deploy.sh de/nl/all [--with-singbox], проверки после деплоя
- **Watchdog + cron**: автоперезапуск singbox при падении

### 2026-04-09: User API + Admin

- **sing-box fork** задеплоен (v1.13.6-userapi) на DE + NL
- **User API**: REST на :15380, add/remove/list без перезапуска
- **UserAPIClient** в chameleon: API first, SIGHUP fallback
- **Метрики нод**: CPU/RAM/Disk/traffic/speed/connections

### 2026-04-09: Multi-node + Rust cleanup

- Cluster sync, server CRUD, per-server Reality ключи
- Universal deploy.sh, config.production.yaml шаблон
- Rust backend удалён (104 файла, 8.5GB)

### 2026-04-09: DNS loop fix + SNI

- Отсутствовал `{"action":"sniff"}` → DNS loop. Исправлено.
- SNI: ads.x5.ru → ads.adfox.ru (40% timeout исправлено)

### Что пробовали и НЕ работает

| Подход | Результат | Причина |
|---|---|---|
| `stack: "mixed"` | Трафик не идёт | gVisor TCP + system UDP конфликт с NetworkExtension |
| `stack: "gvisor"` | DE: 4.2 Kbps | userspace ломает DE direct, NL OK (62 Mbps) |
| QUIC без reject | Медленнее | QUIC-over-TCP хуже чем HTTP/2-over-TCP |
| Random short_id | reality verification failed | Не в списке допустимых сервера |
| Reality keys в .env | Рассинхрон | 3 места → ключи расходились |
| Xray v26 + sing-box 1.13 | Несовместимо | Protocol mismatch |
| sing-box mux h2mux + Xray сервер | Несовместимо | Multiplexing protocol mismatch |

---

## Stable Tags

- **`v0.3-stable-no-flooding`** (b385e56, 2026-04-08) — no_drop fix + system stack
- **`v0.4-clean`** — Rust backend удалён, только Go

---

## Topology snapshot (2026-04-23)

> **Single source of truth:** `infrastructure/topology.yaml` (структурированные данные, всегда актуальнее этого блока). При расхождении — верить YAML.
> **Известные unknown:** реальные SNI и порт DE VLESS — только в БД. Проверка: `ssh ubuntu@162.19.242.30` → `sudo docker exec chameleon-postgres psql -U chameleon -d chameleon -c "SELECT id,name,host,port,sni FROM vpn_servers"`. См. `inconsistencies` в YAML.

### Infrastructure map

```
┌─────────────────────────────────────────────────────────────────────┐
│                        iOS App (MadFrog)                            │
└────────────────────────┬────────────────────────────────────────────┘
                         │
         ┌───────────────┴───────────────┐
         │                               │
    ┌────▼────────────────────┐   ┌─────▼─────────────────────┐
    │   API Race (fastest)     │   │    VPN Tunnel             │
    └────┬────────────────────┘   └─────┬─────────────────────┘
         │                              │
    ┌────┴────────────────────────┐ ┌──┴────────────────────────┐
    │ 1. api.madfrog.online       │ │ Auto urltest selector     │
    │    (Cloudflare DNS)         │ │ picks best available:     │
    │    timeout: 8s              │ │                           │
    │                             │ │ - DE direct (VLESS:2096)  │
    │ 2. 162.19.242.30:443        │ │ - NL direct (VLESS:2096)  │
    │    (SNI spoof + nwconnect)  │ │ - SPB relay→DE (tcp:443)  │
    │    timeout: 6s              │ │ - SPB relay→NL (tcp:2098) │
    │                             │ │ - H2 UDP, TUIC UDP        │
    │ 3. 147.45.252.234:443       │ │ - or H2/TUIC variants     │
    │    (SNI spoof + nwconnect)  │ │                           │
    │    timeout: 6s              │ │ Routing modes via selectors:
    │                             │ │ - RU Traffic selector     │
    │ 4. 185.218.0.43:80          │ │ - Blocked Traffic selector
    │    (SPB relay, HTTP)        │ │ - Default Route selector  │
    │    timeout: 6s              │ │                           │
    │                             │ │ DNS: Yandex direct for .ru
    │ (cascade on 4xx/5xx)        │ │ rules, Cloudflare remote  │
    └─────────────────────────────┘ └──────────────────────────┘
         │                              │
         │ HTTP + TLS SNI spoof         │ sing-box client
         │                              │ (TUN + rules)
    ┌────▼──────────────────────────────▼─────────────┐
    │              Sing-box Server Node                │
    │              (xray inbound)                      │
    ├──────────────────────────────────────────────────┤
    │ DE (162.19.242.30) — OVH Frankfurt              │
    │   Inbounds:                                      │
    │   - VLESS Reality/TCP  :443  (sni: ads.adfox)   │
    │   - Hysteria2 UDP      :443                      │
    │   - TUIC v5 UDP        :8443                     │
    │   Client sees as      :2096 (VLESS)             │
    │                       :443  (H2)                 │
    │                       :8443 (TUIC)              │
    │                                                  │
    │ NL (147.45.252.234) — Timeweb                    │
    │   Inbounds:                                      │
    │   - VLESS Reality/TCP  :2096 (sni: ads.adfox)   │
    │   - Hysteria2 UDP      :8443                     │
    │   - TUIC v5 UDP        :8443                     │
    │   Client sees as      :2096 (VLESS)             │
    │                       :8443 (H2/TUIC)           │
    │                                                  │
    │ SPB Relay (185.218.0.43) — nginx TCP tunneling   │
    │   :443   → DE:443   (VLESS Reality)              │
    │   :2096  → DE:2096  (VLESS to DE)                │
    │   :2098  → NL:2096  (VLESS to NL)                │
    │   :80    → DE:80    (HTTP fallback)              │
    │                                                  │
    └──────────────────────────────────────────────────┘
         │
    ┌────▼──────────────────────────────────────────────┐
    │        Backend + API (chameleon Go)               │
    │        Deployed on each node:8000                │
    │  - Config generation (POST /api/v1/mobile/config)│
    │  - User auth (register/activate/apple-signin)    │
    │  - Subscription mgmt                             │
    │  - Metrics/health                                │
    │  - Cluster sync via Redis                        │
    └──────────────────────────────────────────────────┘
```

### VPN client outbounds (sing-box)

```
Global fallback chain (when a server fails):

Proxy (selector)
  ├─ Auto (urltest) [default]
  │   └─ tests 6 members every 3 minutes:
  │       ├─ VLESS 🇩🇪 Germany (2096)
  │       ├─ VLESS 🇳🇱 Netherlands (2096)
  │       ├─ H2 🇩🇪 Germany (443 UDP)
  │       ├─ H2 🇳🇱 Netherlands (8443 UDP)
  │       ├─ TUIC 🇩🇪 Germany (8443 UDP)
  │       ├─ TUIC 🇳🇱 Netherlands (8443 UDP)
  │       └─ picks fastest (excludes >400ms latency)
  └─ Manual selector (user can override Auto)
     └─ all 6 + 2 relay variants

Selector chains for split tunneling:
  RU Traffic → (smart: direct | ru-direct: direct | full-vpn: Proxy)
  Blocked Traffic → (smart: Proxy | ru-direct: Proxy | full-vpn: Proxy)
  Default Route → (smart: direct | ru-direct: Proxy | full-vpn: Proxy)

DNS resolution:
  .ru zones → Yandex DoH (77.88.8.8)
  Other → Cloudflare DoH (1.1.1.1)
  FakeIP for hijacked queries (198.18.0.0/15)
```

### API endpoint race logic

```
All iOS API calls (register, config, auth) use dataWithFallback():

task_group {
  T0: POST https://api.madfrog.online  [through Cloudflare]
      timeout: 8s
      
  T1: POST https://162.19.242.30:443   [direct, SNI spoof]
      NWConnection with custom SNI = api.madfrog.online
      timeout: 6s
      
  T2: POST https://147.45.252.234:443  [direct, SNI spoof]
      NWConnection with custom SNI = api.madfrog.online
      timeout: 6s
      
  T3: POST http://185.218.0.43:80      [SPB relay HTTP]
      standard URLSession
      timeout: 6s
      
  T4: POST http://162.19.242.30:80     [DE HTTP fallback]
      standard URLSession (insecure delegate)
      timeout: 8s
}

Winner: first task to return 2xx (ignores 5xx/timeouts)
           cancels all others immediately
Success: average 300-800ms (T1-2 win in most regions)
Failure: all 5 tasks timeout → user sees error
