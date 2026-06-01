---
title: System Overview
date: 2026-05-28
status: active
tags: [architecture, overview]
---

# Chameleon VPN — system overview

One-pager. For depth: [mesh.md](mesh.md) (topology detail — note the v2 scale plan is aspirational), [target.md](target.md) (historical April draft), [`../decisions/`](../decisions/) (why we chose what). Live state: [`../state/project.yaml`](../state/project.yaml).

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

## Operational truths (as of 2026-06-01)

> Live snapshot is [`../state/project.yaml`](../state/project.yaml) — read that first; these bullets are the narrative gloss.

- 🟢 **1.0.28 build 91 LIVE** on App Store; **1.0.29 build 98** on TestFlight (pending submit). EventTracker telemetry → `/admin/app/events`.
- 🟢 **IAPs APPROVED** (all 4, 2026-05-31). Monetization unblocked (non-CIS via StoreKit; RU/CIS via WebPaywall/FreeKassa).
- 🟢 **Two VPN exits**: NL (147.45.252.234) + GRA/France (54.38.243.162), plus MSK & SPB RU relays. Backend/DB is still single-NL — that SPoF is the open redundancy item (NL-RED-01, [`../decisions/0004-single-nl-spof.md`](../decisions/0004-single-nl-spof.md)).
- 🟡 Per-user traffic only counted on the NL exit (TRAFFIC-MULTIEXIT). Lint debt: see `roadmap.yaml` → stats.tech_debt_items.

## When this overview is wrong

The state YAMLs are authoritative; this overview is just orientation. If anything here disagrees with [`../state/`](../state/), believe state/.
