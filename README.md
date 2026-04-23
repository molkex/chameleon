# Chameleon VPN

> 🤖 Mirror: [agent-readable YAML](README.yaml) — keep in sync. Edit either, sync the other.

Self-hosted VPN platform: Go backend + sing-box + native iOS/macOS app.

## Architecture

Each node is an autonomous instance running the full stack:

```
iOS / macOS App (sing-box / libbox)
       |
       v
+------------------------------------------+
|           Nginx reverse proxy            |
|  /api/mobile  /api/admin  /sub           |
+------------------------------------------+
                |
                v
+------------------------------------------+
|        Go Backend (Echo, port 8000)      |
|                                          |
|  Mobile API | Admin API | Cluster Sync   |
|        |          |           |          |
|        v          v           v          |
|     PostgreSQL  Redis    sing-box 1.13   |
+------------------------------------------+
```

Nodes sync users via cluster (Redis Pub/Sub + HTTP fallback).

## Stack

- **Backend:** Go (Echo framework)
- **VPN Engine:** sing-box 1.13 (VLESS Reality TCP)
- **Admin SPA:** React 19, TailwindCSS 4, shadcn/ui
- **iOS/macOS:** Swift 6, SwiftUI, NetworkExtension, libbox 1.13
- **Database:** PostgreSQL 16
- **Cache:** Redis 7
- **Deploy:** Docker Compose, rsync

## Project Structure

```
chameleon/
├── backend/           # Go backend (primary)
│   ├── cmd/chameleon/    # Binary entrypoint
│   ├── internal/         # API, VPN engine, auth, cluster
│   ├── migrations/       # SQL schema
│   ├── docker-compose.yml
│   └── deploy.sh         # Multi-node deploy script
├── clients/admin/                # React admin SPA
├── clients/apple/                # iOS + macOS apps
│   ├── MadFrogVPN/     # Main app target
│   ├── PacketTunnel/     # VPN extension
│   └── Shared/           # Common code
├── infrastructure/       # Nginx, backup/restore
└── docs/                 # Documentation
```

## Deploy

```bash
# Deploy to a specific node
cd backend
./deploy.sh de    # Germany
./deploy.sh nl    # Netherlands
```

Secrets are loaded from `~/.secrets.env` on the deploy machine.

## Servers

| Node | IP | Role |
|---|---|---|
| DE | 162.19.242.30 | Backend + VPN |
| NL | 194.135.38.90 | Backend + VPN |
| SPB | 185.218.0.43 | TCP relay |
