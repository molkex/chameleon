---
title: Repo map
date: 2026-06-26
status: active
tags: [architecture, map]
---
# Repo map — what is where and why

Quick orientation for a cold-start session. For design rationale see `arch/overview.md`; for live facts see `docs/state/*.yaml`.

---

## Top-level layout

| Path | What lives there |
|---|---|
| `backend/` | Go API server, VPN engine, DB migrations, Docker config |
| `clients/admin/` | React admin SPA (internal ops dashboard) |
| `clients/apple/` | iOS + macOS Swift/SwiftUI app + NetworkExtension targets |
| `clients/widget/` | iOS lock-screen widget (legacy stub, superseded by `MadFrogWidget` target) |
| `infrastructure/` | Shell scripts + nginx configs for relay nodes (MSK, SPB) and monitoring |
| `backups/` | Point-in-time inventory snapshots (frozen) |
| `docs/` | All project documentation (see `docs/README.md`) |

---

## backend/

Go 1.25, Echo v4, pgx/v5, go-redis/v9, zap.

### cmd/

| Binary | Purpose |
|---|---|
| `cmd/chameleon/` | Main server entrypoint — wires all internal packages, starts HTTP + lifecycle |
| `cmd/ascinit/` | One-shot CLI — bootstraps App Store Connect metadata (IAP products, localizations) |
| `cmd/metrics-agent/` | Sidecar that scrapes internal metrics and exposes Prometheus endpoint |

### internal/

| Package | One-line purpose |
|---|---|
| `api/mobile/` | HTTP handlers for the iOS/macOS app (auth, VPN config fetch, payments, push) |
| `api/admin/` | HTTP handlers for the admin SPA (users, nodes, promo, announcements, support) |
| `api/middleware/` | JWT auth, rate limiting, request logging |
| `asc/` | App Store Connect API client — receipt validation, subscription status, build queries |
| `auth/` | JWT issuance + validation, device registration, Apple/Google sign-in, magic-link email |
| `cluster/` | Multi-node user-sync — replicates VPN users to GRA (France) exit node via Xray User API |
| `config/` | Config struct loaded from env vars at startup |
| `db/` | pgx connection pool, migration runner, typed query helpers |
| `email/` | Transactional email via Resend (magic-link, welcome) |
| `geoip/` | MaxMind GeoLite2 lookup — country/city from IP for routing and analytics |
| `lifecycle/` | Graceful shutdown coordination across goroutines |
| `metrics/` | Internal counters + gauges (connection counts, auth events, VPN health) |
| `payments/apple/` | StoreKit 2 server-to-server notifications + receipt verification |
| `payments/freekassa/` | FreeKassa webhook handler for RU card payments |
| `promo/` | Promo code CRUD and redemption |
| `push/` | APNs push notification dispatch (VPN status, announcements) |
| `secrets/` | Env-based secret loading with validation on startup |
| `storage/` | Redis-backed ephemeral storage (sessions, nonces, device tokens) |
| `useragent/` | User-agent parsing to detect iOS vs macOS vs simulator |
| `vpn/` | sing-box config generation (`clientconfig.go`), VPN engine lifecycle (`engine.go`), Xray User API bridge (`v2rayapi/`) |

### Other backend paths

| Path | Purpose |
|---|---|
| `migrations/` | Sequential SQL migrations (Postgres 16), numbered `NNN_<desc>.sql` |
| `tests/integration/` | Integration tests against real DB + Redis (requires `docker compose up`) |
| `tests/e2e/` | End-to-end API tests |
| `grafana/` | Grafana dashboard JSON + provisioning configs (deployed to NL) |
| `landing/app/` | Static HTML/CSS landing pages served by the backend at `/` |
| `scripts/test/` | Helper scripts for running test suites locally |

---

## clients/admin/

React 19, TailwindCSS 4, shadcn/ui, TanStack Router + Query, Vite 7, vitest.

| Path | Purpose |
|---|---|
| `src/pages/` | One file per admin page (dashboard, users, nodes, servers, promo, push, inbox, audit, shield, funnel, events, announcements, settings, protocols, admins, login, status) |
| `src/components/` | Shared UI — layout chrome, common widgets, shadcn/ui re-exports |
| `src/hooks/` | `use-auth`, `use-command`, `use-mobile`, `use-theme` |
| `src/lib/api.ts` | Typed fetch wrapper for all backend admin API calls |
| `src/lib/devices.ts` | Device-related helpers |
| `src/lib/format.ts` | Date/number/size formatting utilities |
| `src/lib/constants.ts` | Shared constants (env, URLs) |
| `src/test/` | vitest setup + mocks |
| `dist/` | Built output (served by nginx on NL) |

---

## clients/apple/

Swift 6, SwiftUI, iOS 17+ / macOS 14+, NetworkExtension, StoreKit 2, Libbox (sing-box 1.13).

### Targets (4 app targets + 1 widget)

| Target | Bundle ID | Purpose |
|---|---|---|
| `MadFrogVPN` | `com.madfrog.vpn` | iOS main app |
| `PacketTunnel` | `com.madfrog.vpn.tunnel` | iOS NetworkExtension (runs sing-box in-process) |
| `MadFrogVPNMac` | `com.madfrog.vpn.mac` | macOS main app (separate App Store listing) |
| `PacketTunnelMac` | `com.madfrog.vpn.mac.tunnel` | macOS NetworkExtension |
| `MadFrogWidget` | `com.madfrog.vpn.widget` | iOS lock-screen + home-screen widget (since build 82) |

### MadFrogVPN/Models/ (shared iOS + macOS)

| File | Purpose |
|---|---|
| `VPNManager.swift` | Wraps NEVPNManager — connect/disconnect, status polling, 30s connect timeout |
| `AppState.swift` | Top-level observable state — auth, VPN status, retry logic, scenePhase |
| `APIClient.swift` | All backend HTTP calls; races CF + direct-IP legs for RU users |
| `SubscriptionManager.swift` | StoreKit 2 — product fetch, purchase, restore, entitlement check |
| `EventTracker.swift` | Telemetry events (USR-09 Phase 2) — funnel, error, VPN lifecycle |
| `ConfigStore.swift` | Persists fetched sing-box config to App Group container |
| `TrafficHealthMonitor.swift` | Detects stalled VPN traffic; triggers reconnect |
| `PingService.swift` | Latency probe per server node |
| `CommandClient.swift` | Polls backend for server-push commands (announcements, force-update) |
| `ServerGroup.swift` | Model for server/relay grouping and selection |

### MadFrogVPN/Views/ (key views)

| File | Purpose |
|---|---|
| `MainView.swift` | Root — dispatches to Calm/Neon theme variant |
| `PaywallView.swift` / `PaywallRouter.swift` | Subscription purchase flow |
| `OnboardingView.swift` | First-launch onboarding |
| `AccountView.swift` | User profile, sign-out, restore purchases |
| `SupportChatView.swift` | In-app support chat |
| `WebPaywallView.swift` | WKWebView paywall for RU card payments (FreeKassa) |

### PacketTunnel/

| File | Purpose |
|---|---|
| `ExtensionProvider.swift` | `NEPacketTunnelProvider` — `startTunnel`, `stopTunnel`, sing-box lifecycle |
| `ExtensionPlatformInterface.swift` | Bridge between sing-box (Libbox) and NetworkExtension APIs |
| `PacketTunnelProvider.swift` | Thin wrapper that instantiates `ExtensionProvider` |
| `RealTrafficStallDetector.swift` | Detects zero-traffic stalls inside the extension |
| `TunnelStallProbe.swift` | Active probe (ICMP-like) to confirm tunnel liveness |

### Shared/

| File | Purpose |
|---|---|
| `Constants.swift` | `AppConstants.baseURL`, backend IPs, App Group ID, feature flags |
| `KeychainHelper.swift` | Keychain read/write (with App Group access group) |
| `PlatformDevice.swift` | Device info safe for use inside a NE extension |
| `Logger.swift` | Unified os.Logger wrapper |
| `TunnelFileLogger.swift` | File-based logger for extension (written to App Group container) |
| `Networking/` | Low-level NWConnection helpers for the RU SNI-decoy auth race |
| `StallSignals.swift` | Shared stall-detection signals between app and extension |

### Frameworks/

| Path | Purpose |
|---|---|
| `Frameworks/Libbox.xcframework` | Vendored sing-box 1.13.5 XCFramework (480 MB, git-ignored). Fetch: `scripts/fetch-libbox.sh` |

### scripts/ and Tests/

| Path | Purpose |
|---|---|
| `scripts/fetch-libbox.sh` | Downloads Libbox.xcframework from GitHub Release `libbox-v1.13.5` |
| `Tests/UnitTests/` | Swift unit tests (compile-only in CI — app-group host crash in unsigned sim) |

---

## infrastructure/

Shell + nginx configs deployed to relay nodes. Not containerized.

| Path | Purpose |
|---|---|
| `deploy/` | `install.sh` / `update.sh` / `enable-ssl.sh` — initial NL node bootstrap |
| `msk-relay/` | nginx configs for MSK relay (217.198.5.52): API proxy, VPN chain forwarder, decoy SNI block |
| `spb-relay/` | nginx stream + TCP forwarder configs for SPB relay (185.218.0.43) |
| `gra-monitor/` | Health-check + Telegram alert scripts for GRA ↔ NL connectivity |
| `monitoring/` | RU auth health-check script (cron on MSK, alerts if sign-in breaks) |
| `backup.sh` / `restore.sh` | Postgres dump to Backblaze B2 + restore procedure |

---

## docs/

See `docs/README.md` for the full table. Key sub-paths:

| Path | Format | Purpose |
|---|---|---|
| `state/*.yaml` | YAML | Live facts — servers, app-store IDs, runtime, domains, payment-providers, test-map |
| `arch/*.md` | MD | System design narrative (overview, vpn, backend, payments, mesh, target, this file) |
| `decisions/` | MD | ADRs 0001–0012; append-only |
| `incidents/` | MD | Post-mortems; append-only |
| `playbooks/` | MD | Runbooks: deploy, release, debug, recover |
| `release-notes/` | MD | Per-build user-facing notes |
| `audits/` | MD | Point-in-time audits (active ones from 2026-06 onward) |
| `archive/` | mixed | Frozen: 2026-04 prototypes, 2026-05 superseded audits, 2026-06 retired plans |
| `roadmap.yaml` | YAML | Single roadmap: now / next / later / done |
