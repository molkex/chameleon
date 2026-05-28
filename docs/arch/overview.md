---
title: System Overview
date: 2026-05-28
status: active
tags: [architecture, overview]
---

# Chameleon VPN — system overview

One-pager. For depth: [mesh.md](mesh.md) (current state), [target.md](target.md) (where we're heading), [`../decisions/`](../decisions/) (why we chose what).

## What we ship

A native iOS / macOS VPN app (MadFrog VPN) with our own backend, payments (StoreKit for non-CIS + FreeKassa for CIS), an admin SPA for operations, and a sing-box-based VPN engine.

## Major components

```
┌─────────────────────────────────────────────────────────────────┐
│  iOS / macOS app (clients/apple)                                │
│  - SwiftUI views, EventTracker, SubscriptionManager (StoreKit2) │
│  - NetworkExtension PacketTunnel hosting sing-box (libbox 1.13) │
└───┬─────────────────────────────────────────────────────────────┘
    │ HTTPS (api.madfrog.online via MSK relay, or direct NL/SPB fallback)
    │
┌───▼─────────────────────────────────────────────────────────────┐
│  NL backend (147.45.252.234) — sole production node             │
│                                                                  │
│  nginx ┬─→ chameleon (Go binary, internal/api/{mobile,admin})   │
│        ╰─→ /admin/app → admin SPA static bundle (Vite + TanStack)│
│                                                                  │
│  postgres-16 + redis-7  (in docker compose)                     │
│  singbox  (standalone container, VLESS Reality on :443/tcp)     │
│  singbox-log-watcher (cron, MON-06)                             │
│  metrics-agent (node metrics → DB)                              │
└─────────────────────────────────────────────────────────────────┘
```

For the iOS network race, the MSK API relay, and the SPB TCP fallback, see [mesh.md](mesh.md).

## Repo layout

```
chameleon/
├── backend/              Go API + migrations + deploy.sh + Dockerfile + cmd/{chameleon,ascinit,metrics-agent}
├── clients/
│   ├── admin/            React 19 SPA (Vite, TanStack Router/Query, shadcn/ui)
│   └── apple/            iOS + macOS via XcodeGen (Swift 6, SwiftUI, libbox 1.13)
├── infrastructure/
│   ├── deploy/           shared deploy helpers
│   ├── spb-relay/        nginx config mirror for SPB relay
│   └── topology.yaml     legacy detailed mesh map (will fold into state/ over time)
└── docs/                 you are here. See ../README.md for conventions.
```

## Critical paths

- **iOS connects** → see [mesh.md](mesh.md#ios-network-race).
- **Backend deploy** → [`../playbooks/deploy-nl.md`](../playbooks/deploy-nl.md).
- **iOS release via CLI** → [`../playbooks/ios-cli-release.md`](../playbooks/ios-cli-release.md).
- **Apple rejection recovery** → [`../playbooks/apple-reject-recovery.md`](../playbooks/apple-reject-recovery.md).

## Operational truths (as of 2026-05-28)

- 🟢 1.0.27 build 90 LIVE on App Store. EventTracker shipping telemetry → `/admin/app/events`.
- 🟡 IAPs still in review (re-submitted 2026-05-28). Monetization blocked until APPROVED.
- 🔴 NL is single point of failure. Hetzner Helsinki is the planned redundancy host ([`../decisions/0004-single-nl-spof.md`](../decisions/0004-single-nl-spof.md)).
- 🟡 Pre-existing lint debt cataloged: see `roadmap.yaml` → tech_debt.

## When this overview is wrong

The state YAMLs are authoritative; this overview is just orientation. If anything here disagrees with [`../state/`](../state/), believe state/.
