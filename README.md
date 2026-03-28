# Chameleon VPN

> Modular, scalable VPN management engine with protocol plugin architecture.

Chameleon VPN is a self-hosted VPN management platform that supports 10+ protocols as plugins, dynamic user provisioning via xray gRPC API, server-controlled protocol failover, and health-aware subscription delivery. It scales from a single server with 100 users to a distributed multi-node deployment serving 1,000,000+.

## Features

- **10 VPN protocols as plugins** -- VLESS Reality (TCP/gRPC), VLESS WS CDN, Hysteria2, AmneziaWG 2.0, WARP+ WireGuard, AnyTLS, NaiveProxy, XDNS, XICMP
- **Dynamic user management** via xray gRPC Stats API (5ms add/remove, zero restarts)
- **ChameleonShield** -- server-controlled protocol priority and failover; react to censorship without app updates
- **ChameleonEngine** -- central orchestrator coordinating protocols, shield, fallback chains, padding, and SNI rotation
- **Event-driven node management** with pull-based config API and circuit breaker
- **Traffic padding** and **SNI rotation** (health-aware, auto-excludes blocked SNIs)
- **Config versioning** with ETag/304 -- clients only download when config changes
- **Admin API** with RBAC (admin / operator / viewer)
- **Admin SPA** -- React 19 dashboard with 20+ pages (users, nodes, protocols, monitoring, settings)
- **Mobile API** -- sign-in with Apple, StoreKit 2 subscription verification, sing-box config delivery
- **Apple apps** -- native iOS and macOS clients (SwiftUI + sing-box / libbox)
- **Plugin system** for adding protocols, admin panel extensions, and webhook integrations

## Architecture

```
iOS / macOS App          Admin SPA (React)
       |                        |
       v                        v
  +-----------------------------------------+
  |          Nginx reverse proxy            |
  |  /api/v1/mobile  /api/v1/admin  /sub   |
  +-----------------------------------------+
                    |
                    v
  +-----------------------------------------+
  |        FastAPI Backend (Docker)         |
  |                                         |
  |  +----------+  +---------+  +---------+ |
  |  | Mobile   |  | Admin   |  | VPN     | |
  |  | API      |  | API     |  | Core    | |
  |  +----------+  +---------+  +---------+ |
  |        |            |            |       |
  |        v            v            v       |
  |  +-----------------------------------+  |
  |  |   PostgreSQL  +  Redis            |  |
  |  +-----------------------------------+  |
  +-----------------------------------------+
              |
              v  (pull-based node API)
  +----------------+    +----------------+
  |  Xray Node 1   |    |  Xray Node 2   |
  +----------------+    +----------------+
```

## Quick Start

### Prerequisites

- Python 3.11+
- PostgreSQL 16+
- Redis 7+
- Xray-core v26+

### Installation

```bash
# Clone
git clone https://github.com/your-org/chameleon-vpn.git
cd chameleon-vpn

# Install backend
cd backend
pip install -e ".[dev]"

# Configure
cp ../.env.example ../.env
# Edit .env with your settings (database, redis, xray, etc.)

# Run database migrations
alembic upgrade head

# Start
uvicorn app.main:create_app --factory --host 0.0.0.0 --port 8000
```

### Docker (recommended)

```bash
cd infrastructure/docker
cp ../../.env.example ../../.env
# Edit .env

docker compose -f docker-compose.management.yml up -d
```

## Adding a New Protocol

Chameleon uses a plugin architecture. Adding a protocol takes three steps:

**1. Create the plugin** (`backend/app/vpn/protocols/my_protocol.py`):

```python
from app.vpn.protocols.base import ProtocolPlugin, ProtocolInfo

class MyProtocol(ProtocolPlugin):
    @property
    def info(self) -> ProtocolInfo:
        return ProtocolInfo(
            name="my_protocol",
            display_name="My Protocol",
            transport="tcp",
            default_port=12345,
        )

    def generate_outbound(self, user, server) -> dict:
        """Return a sing-box outbound config dict."""
        return { ... }

    def generate_link(self, user, server) -> str:
        """Return a subscription link string."""
        return f"my-proto://..."
```

**2. Register it** (`backend/app/vpn/protocols/__init__.py`):

```python
from .my_protocol import MyProtocol
registry.register(MyProtocol())
```

**3. Enable it** in your `.env` or admin panel -- ChameleonShield will pick it up automatically.

## Configuration

Key environment variables (see `.env.example` for full list):

| Variable | Description | Default |
|---|---|---|
| `DATABASE_URL` | PostgreSQL connection string | required |
| `REDIS_URL` | Redis connection string | `redis://127.0.0.1:6379/0` |
| `XRAY_API_HOST` | Xray gRPC Stats API host | `127.0.0.1` |
| `XRAY_API_PORT` | Xray gRPC Stats API port | `10085` |
| `REALITY_PRIVATE_KEY` | VLESS Reality private key | required |
| `REALITY_PUBLIC_KEY` | VLESS Reality public key | required |
| `HY2_PASSWORD` | Hysteria2 auth password | required |
| `ADMIN_SESSION_SECRET` | Admin panel session secret | required |
| `WEBHOOK_BASE_URL` | Public URL for webhooks | optional |
| `CLOUDFLARE_API_KEY` | Cloudflare API key (for CDN protocol) | optional |

## API Endpoints

### Mobile API (`/api/v1/mobile/`)

| Method | Path | Auth | Description |
|---|---|---|---|
| POST | `/auth/apple` | -- | Sign in with Apple |
| POST | `/auth/refresh` | refresh_token | Refresh token pair |
| GET | `/config` | Bearer | sing-box JSON config |
| GET | `/servers` | Bearer | Server list with health/ping |
| GET | `/subscription` | Bearer | Subscription status |
| POST | `/subscription/verify` | Bearer | Verify StoreKit receipt |

### Admin API (`/api/v1/admin/`)

| Method | Path | Auth | Description |
|---|---|---|---|
| POST | `/auth/login` | -- | Admin login (JWT) |
| GET | `/stats/dashboard` | admin | Dashboard metrics |
| GET | `/users` | operator+ | User list |
| GET | `/nodes` | viewer+ | Node status |
| GET | `/protocols` | viewer+ | Protocol configuration |
| PATCH | `/settings/*` | admin | Branding, WARP, etc. |

### Subscription (`/sub/`)

| Method | Path | Description |
|---|---|---|
| GET | `/sub/{token}` | VLESS/HY2 subscription links |
| GET | `/sub/{token}/smart` | sing-box JSON config (with ETag) |

## Project Structure

```
chameleon/
├── backend/
│   ├── app/
│   │   ├── vpn/                    # Chameleon Core
│   │   │   ├── protocols/          # Protocol plugins (10)
│   │   │   │   ├── base.py         # ProtocolPlugin ABC
│   │   │   │   ├── registry.py     # Plugin registry
│   │   │   │   ├── vless_reality.py
│   │   │   │   ├── vless_cdn.py
│   │   │   │   ├── hysteria2.py
│   │   │   │   ├── warp.py
│   │   │   │   ├── anytls.py
│   │   │   │   ├── naiveproxy.py
│   │   │   │   ├── xdns.py
│   │   │   │   └── xicmp.py
│   │   │   ├── engine.py           # ChameleonEngine
│   │   │   ├── shield.py           # ChameleonShield
│   │   │   ├── xray_api.py         # Xray gRPC management
│   │   │   ├── fallback.py         # Fallback chain builder
│   │   │   ├── padding.py          # Traffic padding
│   │   │   ├── sni_rotation.py     # SNI rotation
│   │   │   ├── config_version.py   # Config versioning (ETag)
│   │   │   ├── node_api.py         # Pull-based node API
│   │   │   ├── rate_limiter.py     # Per-user rate limiter
│   │   │   ├── webhooks.py         # Event emitter
│   │   │   ├── singbox_config.py   # sing-box config generator
│   │   │   ├── links.py            # Subscription link generator
│   │   │   ├── users.py            # User management
│   │   │   └── nodes.py            # Node management
│   │   ├── api/
│   │   │   ├── admin/              # Admin REST API
│   │   │   ├── mobile/             # Mobile REST API
│   │   │   └── webhooks/           # Apple/payment webhooks
│   │   ├── auth/                   # JWT auth, RBAC, StoreKit
│   │   ├── monitoring/             # Node metrics, traffic
│   │   ├── database/               # SQLAlchemy models, Alembic
│   │   ├── config.py               # pydantic-settings config
│   │   ├── main.py                 # FastAPI app factory
│   │   └── dependencies.py         # DI providers
│   └── pyproject.toml
├── admin/                          # React 19 admin SPA
├── apple/                          # iOS + macOS apps (SwiftUI)
├── infrastructure/
│   ├── docker/                     # Docker Compose files
│   ├── nginx/                      # Nginx configs
│   ├── xray/                       # Xray config templates
│   └── watchdog.py                 # Auto-failover watchdog
├── .env.example
├── ARCHITECTURE.md
├── CONTRIBUTING.md
└── LICENSE
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style, and PR process.

## License

[MIT](LICENSE)
