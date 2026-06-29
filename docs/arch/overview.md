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
    │ HTTPS (api.madfrog.online via MSK relay, or direct WAW/SPB fallback)
    │
┌───▼─────────────────────────────────────────────────────────────┐
│  WAW backend (217.182.74.70) — PRIMARY backend+DB since 2026-06-29 │
│                                                                  │
│  chameleon-failover (Go binary :8000, internal/api/{mobile,admin})│
│  chameleon-postgres-standby (promoted, writable postgres:16)    │
│  redis                                                           │
│  singbox  (standalone container, VLESS Reality on :443/tcp)     │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  NL (147.45.252.234) — streaming REPLICA of WAW (since 2026-06-29) │
│                                                                  │
│  chameleon backend: STOPPED; nl2 VPN exit: DEACTIVATED          │
│  postgres: read-only streaming replica of WAW (~0.05 s lag)     │
│  singbox-log-watcher + metrics-agent still running              │
└─────────────────────────────────────────────────────────────────┘
```

> Failover design: [ADR 0013](../decisions/0013-ha-failover-msk-ingress.md) (MSK-ingress as source of truth, no Patroni).
> Tooling: `infrastructure/failover/{failover.sh,rebuild-replica.sh,waw-backend-up.sh}`.

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
│   └── backup.sh, restore.sh   B2 backup/restore helpers
└── docs/                 you are here. See ../README.md for conventions.
                          mesh facts → state/servers.yaml; VPN shape → arch/vpn.md
```

## Critical paths

- **iOS connects** → see [mesh.md](mesh.md#ios-network-race).
- **Backend deploy (WAW primary)** → `infrastructure/failover/waw-backend-up.sh`; historical NL procedure → [`../playbooks/deploy-nl.md`](../playbooks/deploy-nl.md) (NL is now a replica — see banner at top of that file).
- **iOS release via CLI** → [`../playbooks/ios-cli-release.md`](../playbooks/ios-cli-release.md).
- **Apple rejection recovery** → [`../playbooks/apple-reject-recovery.md`](../playbooks/apple-reject-recovery.md).

## Operational truths (snapshot; see [`../state/project.yaml`](../state/project.yaml) for live state)

> Live snapshot is [`../state/project.yaml`](../state/project.yaml) — read that first; these bullets are the narrative gloss. This section reflects 2026-06-29 post-failover state.

- 🟢 **WAW (217.182.74.70) = PRIMARY backend+DB** since the 2026-06-29 failover. NL is a streaming replica; its chameleon backend is stopped. See [ADR 0013](../decisions/0013-ha-failover-msk-ingress.md).
- 🟢 **Three VPN exits**: WAW/Poland (waw1, primary), GRA/France (54.38.243.162, gra1), NL exit deactivated (is_active=false). MSK & SPB RU relays active. Single-NL SPoF resolved — [ADR 0004](../decisions/0004-single-nl-spof.md) superseded by [ADR 0012/0013](../decisions/).
- 🟢 **IAPs APPROVED** (all 4, 2026-05-31). Monetization unblocked (non-CIS via StoreKit; RU/CIS via WebPaywall/FreeKassa).
- 🟢 **MSK upstream** now points to WAW:8000 (was nl:80).
- 🟡 Per-user traffic only counted on active exits (TRAFFIC-MULTIEXIT). Lint debt: see `roadmap.yaml` → stats.tech_debt_items.

## When this overview is wrong

The state YAMLs are authoritative; this overview is just orientation. If anything here disagrees with [`../state/`](../state/), believe state/.
