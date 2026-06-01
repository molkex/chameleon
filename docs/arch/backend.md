---
title: Backend Code Layout (index)
date: 2026-06-01
status: active
tags: [backend, go, architecture, index]
---

# Chameleon backend — code-layout map

An index into the Go backend, not a spec. **The code is source of truth** — this
points you at the right package. Stack: Go 1.25 + Echo v4 + pgx/v5 + go-redis/v9 +
zap. VPN data-plane shapes live in [vpn.md](vpn.md); topology in [overview.md](overview.md).

## Packages — [`backend/internal/`](../../backend/internal/)

| Package | Responsibility |
|---|---|
| [`api`](../../backend/internal/api/) | Echo server, global middleware, route wiring (`server.go`). |
| [`api/mobile`](../../backend/internal/api/mobile/) | iOS/macOS endpoints: auth, config, subscription, payment, events, account. |
| [`api/admin`](../../backend/internal/api/admin/) | Admin SPA endpoints: users, nodes, servers, stats/dashboard, audit, status, events. |
| [`api/middleware`](../../backend/internal/api/middleware/) | `ratelimit`, `idempotency`, `security` (headers + CSRF). |
| [`auth`](../../backend/internal/auth/) | JWT create/verify, `RequireAuth`/`CookieOrBearerAuth`, Apple + Google verifiers, Argon2id passwords. |
| [`db`](../../backend/internal/db/) | pgx pool + CRUD: users, servers, payments, admin, audit, app_events, funnel, magic_tokens, theme. |
| [`vpn`](../../backend/internal/vpn/) | sing-box engine, client/server config generation, User API client, stats. See [vpn.md](vpn.md). |
| [`cluster`](../../backend/internal/cluster/) | Peer sync (`sync`, `pubsub`, `routes`) + `RelayUserSyncer` (`relay.go`) pushing users to remote exits/relays. |
| [`payments`](../../backend/internal/payments/) | Credit ledger + `apple` (IAP/JWS verify) + `freekassa` (RU/CIS). |
| [`asc`](../../backend/internal/asc/) | App Store Connect API client (Apple state in admin). |
| [`config`](../../backend/internal/config/) | YAML loader, `${ENV}` substitution, validation. |
| [`metrics`](../../backend/internal/metrics/) | Prometheus collectors + background VPN-stats refresher. |
| [`geoip`](../../backend/internal/geoip/) | Country lookup (rate-limit / FreeKassa / routing). |
| [`secrets`](../../backend/internal/secrets/) | AES cipher for provider passwords at rest. |
| [`email`](../../backend/internal/email/) | Sender abstraction + Resend impl (magic links). |
| [`useragent`](../../backend/internal/useragent/) | UA string parsing for telemetry. |
| [`cli`](../../backend/internal/cli/) | `admin create` subcommand. |

## HTTP route groups — wired in [`api/server.go`](../../backend/internal/api/server.go) `setupRoutes`

| Group | Handler package | Notes |
|---|---|---|
| `/api/mobile/*`, `/api/v1/mobile/*` | `api/mobile` | iOS uses the v1 prefix. + rate-limit + idempotency. `RegisterRoutes` in `mobile/routes.go`. |
| `/sub/:token[/:mode]` | `api/mobile` | Legacy config download by subscription token. |
| `/api/webhooks/freekassa` | `api/mobile` | Public S2S webhook (IP allowlist + HMAC inside handler). |
| `/api/v1/admin/*`, `/api/admin/*` | `api/admin` | + rate-limit + CSRF. `RegisterRoutes` in `admin/routes.go`. |
| `/api/cluster/*` | `cluster` | Peer-to-peer `pull`/`push` + `node-status`; bearer `CLUSTER_SECRET`, only if cluster enabled. |
| `/health` | `api/server.go` | No auth/rate-limit; checks DB + Redis. |
| `/metrics` | `metrics` | Prometheus scrape; localhost-bound, outside auth/rate-limit. |

## Global middleware chain (outermost first) — `setupMiddleware`

```
metrics histogram → Recover → BodyLimit(1M) → RequestID
  → zap requestLogger → SecurityHeaders → CORS → ContextTimeout(30s)
```
Per-group middleware (rate-limit, idempotency, CSRF, auth) layers on top inside each
`RegisterRoutes`.

## Entrypoint — [`cmd/chameleon/main.go`](../../backend/cmd/chameleon/main.go)

Startup order: CLI/subcommands → config load+validate → zap logger → Postgres pool →
Redis → JWT + Apple/Google verifiers → sing-box engine (`ModeDocker`) → load active
users → engine `Start` (writes config, signals container) → traffic collector +
Prometheus refreshers → `RelayUserSyncer.Start` → `cluster.Syncer.Start` → Echo
server → graceful shutdown on SIGINT/SIGTERM.

Sibling binaries: [`cmd/ascinit`](../../backend/cmd/ascinit/) (ASC bootstrap),
[`cmd/metrics-agent`](../../backend/cmd/metrics-agent/) (node metrics → DB).
