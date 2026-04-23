# Chameleon Go Backend — Plan

## Architecture

```
                    ┌─────────────────────────────┐
                    │     chameleon (Go binary)    │
                    │                              │
  iOS/Admin ──HTTP──┤  API layer (echo)            │
                    │    ├── /api/mobile/*          │
                    │    └── /api/admin/*           │
                    │                              │
                    │  VPN Engine                   │
                    │    └── sing-box (embedded)    │──── Internet
                    │         ├── VLESS Reality     │
                    │         ├── Stats (in-proc)   │
                    │         └── User mgmt (live)  │
                    │                              │
                    │  Background                   │
                    │    ├── Traffic collector       │
                    │    ├── Config sync (5min)      │
                    │    └── Cluster sync (30s)      │
                    └──────┬───────────┬────────────┘
                           │           │
                      PostgreSQL    Redis
```

## Modules

### 1. config/ — YAML configuration
- Single `config.yaml` replaces 60+ env vars
- Sections: server, database, redis, vpn, auth, cluster
- Validation on startup
- Secrets: env vars override YAML (for Docker secrets)

### 2. db/ — Database layer
- pgx v5 for PostgreSQL
- Same schema as Rust backend (compatible migrations)
- Models: User, VpnServer, AdminUser, TrafficSnapshot
- Queries as methods on a DB struct

### 3. auth/ — Authentication
- JWT (access + refresh tokens)
- Apple Sign-In (JWKS verification)
- Argon2 password hashing
- Device registration (with rate limiting)

### 4. vpn/ — VPN Engine (sing-box embedded)
- Import sing-box as Go library
- Create/start/stop sing-box instance in-process
- User management: add/remove without restart
- Stats collection: direct access to sing-box counters
- Config generation: client config JSON for iOS
- Server config: VLESS Reality TCP on port 2096

### 5. api/mobile/ — Mobile API
- POST /api/mobile/auth/register — device registration
- POST /api/mobile/auth/apple — Apple Sign-In
- GET  /api/mobile/config — sing-box client config
- POST /api/mobile/subscription/verify — App Store verification

### 6. api/admin/ — Admin API
- POST /api/admin/auth/login — admin login
- GET  /api/admin/users — list users with traffic
- DELETE /api/admin/users/:id — delete user
- POST /api/admin/nodes/sync — force config sync
- GET  /api/admin/stats — server metrics

### 7. cluster/ — Multi-node sync
- Pull/push user changes between nodes
- HTTP-based sync (same as Rust version)

## Implementation Order

### Phase 1: Foundation (this session)
Parallel agents:
- Agent A: go.mod + config.yaml + config loader
- Agent B: db layer (pgx + models + queries)
- Agent C: auth module (JWT + password)
- Agent D: main.go + echo server skeleton

### Phase 2: VPN Engine
- Embed sing-box as library
- VLESS Reality inbound
- User management (add/remove)
- Stats collection
- Client config generation

### Phase 3: API
- Mobile endpoints (register, config, auth)
- Admin endpoints (users, nodes, stats)
- Middleware (JWT auth, rate limit, CORS)

### Phase 4: Production
- Cluster sync
- Dockerfile
- docker-compose.yml
- Migration from Rust backend
- Deploy + test

## Key Dependencies
- github.com/labstack/echo/v4 — HTTP framework
- github.com/jackc/pgx/v5 — PostgreSQL
- github.com/redis/go-redis/v9 — Redis
- github.com/sagernet/sing-box — VPN engine (embedded)
- github.com/golang-jwt/jwt/v5 — JWT tokens
- github.com/alexedwards/argon2id — password hashing
- gopkg.in/yaml.v3 — config parsing
- golang.org/x/crypto — crypto utilities

## Config Format
```yaml
server:
  host: 0.0.0.0
  port: 8000

database:
  url: postgres://chameleon:pass@localhost:5432/chameleon?sslmode=disable

redis:
  url: redis://:pass@localhost:6379/0

auth:
  jwt_secret: "${JWT_SECRET}"          # env override for secrets
  jwt_access_ttl: 24h
  jwt_refresh_ttl: 720h
  admin_username: admin
  admin_password: "${ADMIN_PASSWORD}"

vpn:
  listen_port: 2096
  reality:
    private_key: "${REALITY_PRIVATE_KEY}"
    short_ids: ["", "0018e1ec", "2802649f"]
    snis:
      de: ads.x5.ru
      nl: rutube.ru
  servers:
    - key: de
      name: Germany
      host: 162.19.242.30
      port: 2096
      flag: "🇩🇪"
    - key: nl
      name: Netherlands
      host: 194.135.38.90
      port: 2096
      flag: "🇳🇱"
    - key: ru-de
      name: "Russia → DE"
      host: 185.218.0.43
      port: 443
      flag: "🇷🇺"
    - key: ru-nl
      name: "Russia → NL"
      host: 185.218.0.43
      port: 2098
      flag: "🇷🇺"

cluster:
  enabled: false
  node_id: de-1
  sync_interval: 30s
  peers: []
```
