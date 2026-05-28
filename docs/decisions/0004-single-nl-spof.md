---
title: Accept single-NL SPoF for now; Hetzner Helsinki is planned redundancy
date: 2026-05-26
status: active
tags: [infrastructure, risk, roadmap]
---

# 0004 — Single-NL SPoF accepted (with planned exit)

## Context

DE (OVH Frankfurt, 162.19.242.30) was retired 2026-05-25 — contract expired, not renewed. Reasons:

- DE direct connect was unreliable for RU users (Cloudflare throttling on RU networks since 2026-04).
- Consolidating to a single high-quality VPN node was simpler than maintaining DE + NL.
- Cost: one box vs two.

NL (Timeweb, 147.45.252.234) became sole production. There is no failover.

## Decision

**Accept single-NL as the current production posture.** Don't try to maintain DE as cold-standby; the operational cost outweighs the resilience benefit at our scale.

**Plan to add Helsinki (Hetzner, AS24940) as the redundancy node**, not DE. Rationale:

- AS24940 is **not** in RU operator blocklists (as of 2026-05).
- Hetzner pricing is competitive.
- Geographic diversity (Helsinki vs Netherlands) gives EU-wide latency coverage without re-introducing OVH AS pattern Russian users had trouble with.

## Consequences

- If NL goes down, the app can't `/auth/register` or `/api/v1/mobile/config`. **Active VPN sessions survive** (singbox runs its own config, doesn't depend on backend at runtime), but new users can't onboard.
- Health-check alerts (MON-02) trigger on 2-consecutive failures via Telegram (see [`../../backend/scripts/health-check.sh`](../../backend/scripts/health-check.sh)).
- Off-host DB backups to Backblaze B2 are critical — DB recovery needs them since NL itself could be lost.
- iOS clients are designed to gracefully degrade: if `/config` fetch fails, cached config is used.

## Roadmap exit

Tracked in `../roadmap.yaml` → `next.NL-RED-01` (NL redundancy). Multi-hour project: provision Hetzner box, install Docker + singbox + chameleon, add to `vpn_servers` DB, iOS picker test.

## Status

Active. Re-evaluate quarterly. If we hit 1000+ concurrent users on NL, prioritize the Helsinki provisioning.
