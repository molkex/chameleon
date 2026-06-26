---
title: NL redundancy — warm standby (backend+DB) off Timeweb + cheap resilience nets
date: 2026-06-26
status: active
supersedes: 0004   # supersedes the "accept SPoF" posture; the Helsinki target is retained
tags: [infrastructure, redundancy, postgres, failover, nl]
---

# 0012 — NL redundancy: warm standby + resilience nets

## Context

[ADR 0004](0004-single-nl-spof.md) accepted single-NL as the production posture and
parked Helsinki as a "someday" redundancy node. On **2026-06-26** a Timeweb DDoS →
ams-1 regional network outage took the **entire control plane** offline (API, admin,
landing, RU→NL VPN) with no failover and nothing we could do but wait (see
[incident](../incidents/2026-06-26-timeweb-nl-ams1-outage.md)). The SPoF is no longer
an acceptable posture — this ADR supersedes 0004's "accept it" stance and commits to a
concrete design. The Helsinki/Hetzner target from 0004 is **kept**.

The control plane on NL = `chameleon` (stateless Go), `postgres` (stateful, the crown
jewel), `redis` (cache/pubsub, rebuildable), `nginx`, admin SPA + landing (static),
and the RU-API origin reached via the MSK relay. VPN **exits** are already redundant
(NL + GRA); the **brain** is not.

## Decision

Build a **warm standby** of the control plane on a **non-Timeweb** provider
(Hetzner Helsinki, AS24940 — not in RU blocklists per 0004), plus a set of cheap
resilience nets that pay off regardless of the standby.

### Architecture

```
                 ┌────────────── Cloudflare (apex: admin/landing) ──────────────┐
                 │   CF Load Balancing: origin1=NL  origin2=HEL  (health-checked) │
   users ───────►└───────────────────────────────────────────────────────────────┘
                 ┌────────────── api.madfrog.online (RU path, non-CF) ───────────┐
   RU users ────►│  MSK nginx upstream { NL:80 primary;  HEL:80 backup; }         │
                 └───────────────────────────────────────────────────────────────┘
   Postgres:  NL (primary)  ──── streaming replication ───►  HEL (hot standby, read-only)
   Redis:     NL (live)                                       HEL (own instance; cache rebuilds)
   chameleon: NL (active)                                     HEL (deployed, idle until promoted)
```

- **Postgres streaming replication** NL→HEL. RPO ≈ seconds (vs 24h B2-only today).
  HEL standby is read-only until promoted.
- **chameleon + redis + nginx + static** pre-deployed on HEL, idle (DB read-only ⇒
  writes fail safely until promotion).
- **Failover = promote + repoint**, see [playbook nl-failover](../playbooks/nl-failover.md).

### Failover mode: MANUAL first, automate later

Auto-promotion is **rejected for v1** — split-brain risk: if NL is only network-isolated
(today's case) and we auto-promote HEL, NL could resurface as a second primary →
diverging writes. v1 = a single `promote-standby` runbook with explicit fencing
("confirm NL is truly down from ≥2 vantages" + stop NL writes if reachable) + **low DNS
TTL** (300s on `api.madfrog.online`) so only one origin is authoritative. Automate
(health-check → promote → DNS API) only after the manual path is drilled and trusted.

### DB ownership: self-managed replication, NOT managed PG

Managed Postgres is either the same Timeweb (correlated failure) or a RU cloud
(trust/sanctions). Self-managed streaming replication on Hetzner is simpler to reason
about, fully under our control, and cheap.

### Cheap nets (do regardless, some need no standby)

1. **External off-Timeweb monitor on GRA** (OVH): probe origin health + Timeweb
   `finances.hours_left` → TG. Fixes the "health-check runs on the box it monitors"
   blind spot and closes MON-01. *(buildable now, no standby needed)*
2. **MSK nginx `backup` upstream** — one-line failover for the RU API path once HEL exists.
3. **CF Load Balancing** (~$5/mo) — origin failover for the apex so admin/landing don't 522.
4. **Timeweb autopay verify + balance alarm** (`hours_left<72` → TG).
5. **B2 restore drill** — the only DR path must be proven (restore.sh was found broken
   on 2026-06-21 and rewritten; re-verify end-to-end).

## Consequences

- +1 always-on VPS (~€5–15/mo, Hetzner CX/CAX) + ~$5/mo CF LB. Cheap vs a SEV-1.
- RPO drops from 24h (B2) to seconds (replication); RTO becomes minutes (manual promote).
- New ops surface: replication health, failback discipline, DNS TTL hygiene, runbook drills.
- Provisioning the standby host is **human-gated** (no Hetzner account in our secrets
  today — must create one, or order a 2nd OVH VPS in a non-GRA region).

## Rollout (phased — detail in roadmap.yaml#NL-RED-01)

- **Phase 0 (now, no standby needed):** external monitor on GRA, balance alarm, autopay
  check, B2 restore drill, drop `api` DNS TTL to 300s.
- **Phase 1:** provision HEL, install Docker stack, base-backup + streaming replication
  from NL, deploy idle chameleon/redis/nginx/static.
- **Phase 2:** failover runbook + a real drill (promote HEL, flip MSK upstream + DNS,
  verify, fail back).
- **Phase 3 (later):** CF LB origin failover; consider automated promotion.

## Status

Active. Phase 0 starts immediately (parts buildable without NL). Phase 1+ start once NL
recovers from the 2026-06-26 incident and a standby host is provisioned.
