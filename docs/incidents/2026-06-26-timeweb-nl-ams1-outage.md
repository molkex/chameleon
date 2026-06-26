---
title: NL total outage — Timeweb DDoS → ams-1 network unavailability
date: 2026-06-26
status: resolved-pending  # NL recovery gated on Timeweb; doc written during the incident
severity: SEV-1           # full control-plane down (API + admin + RU→NL VPN)
tags: [infrastructure, outage, timeweb, spof, nl]
---

# 2026-06-26 — NL total outage (Timeweb ams-1 network unavailability)

## Summary

For ~30+ minutes (still ongoing at time of writing) the **entire control plane was
down**: `api.madfrog.online` returned 504, the admin SPA returned Cloudflare **522
(Host Error)**, mobile sign-in / config-fetch failed, and all RU→NL VPN chains
(`nl-via-msk`, `ru-spb-nl`) were dead. Root cause was **external**: a DDoS attack on
Timeweb's infrastructure caused a **"Major" network unavailability in their
Netherlands zone (ams-1)**, where our sole backend+DB node (NL, 147.45.252.234) lives.

**Not us:** not billing (account `is_blocked:false`, balance positive), not our
software, not our config. Nothing on our side could restore it — recovery was gated
entirely on Timeweb's engineers.

## Timeline (MSK, UTC+3)

- **15:49** — Timeweb Cloud Alerts (TG): "Фиксируем DDoS-атаку на нашу инфраструктуру. Митигируем…"
- **~16:05** — MSK nginx starts logging `upstream timed out (110) … 147.45.252.234:80`; real users get **504** (client IPs in the access log).
- **16:11** — Timeweb Cloud Alerts: **"Сетевая недоступность в Нидерландах. Зоны: ams-1. Тип: Major. Инженеры занимаются восстановлением."**
- **~16:13** — Triage: NL = 100% packet loss on BOTH IPs (147.45.252.234 + 72.56.79.25) from 3 independent vantages (MSK, SPB, GRA). SSH hangs at banner. Local-Mac probes were misleading (Mac was itself on the VPN → utun default route).
- **~16:15–16:30** — Ruled out billing via `/account/status` (not blocked, balance ok). Issued soft `reboot` then `hard_reboot` via Timeweb API (HTTP 204) — both **froze at status `hard_rebooting`** and never completed (`hard_shutdown` → 400, action-in-progress). These were moot: the host/network was down under the incident.
- **16:11+** — Our own MSK RU-sign-in monitor (cron */5) correctly fired "RU SIGN-IN DOWN — both auth legs unreachable" every 5 min to TG.
- **16:41** — Cloudflare 522 confirmed admin is down too (CF Amsterdam ✅ → origin madfrog.online ❌ Host Error).

## Root cause

Single provider (Timeweb), single region (NL/ams-1), single node holds the **entire
control plane**: backend API, Postgres, Redis, admin SPA, landing, and the RU-API
origin behind the MSK relay. A regional network outage at the provider takes the whole
service offline with **zero failover**. This is exactly the SPoF accepted in
[ADR 0004](../decisions/0004-single-nl-spof.md).

## Blast radius

- 🔴 Mobile sign-in, registration, `/config` fetch — DOWN for everyone.
- 🔴 Admin SPA + landing — DOWN (CF 522).
- 🔴 RU→NL VPN chains (`nl-via-msk`, `ru-spb-nl`) — DOWN.
- 🟢 **France (GRA, OVH)** VPN exit — UNAFFECTED; `fr-via-msk` / `ru-spb-fr` kept carrying traffic.
- 🟢 **Active VPN sessions** that don't need the backend at runtime — survived (sing-box runs its own config).
- 🟢 iOS graceful degradation — cached config kept working where present.

## What worked / what didn't

- ✅ External (off-NL) monitor on MSK alerted us independently.
- ✅ France exit redundancy meant VPN wasn't 100% dark.
- ❌ `backend/scripts/health-check.sh` runs **on NL itself** → when NL died it couldn't alert. A monitor co-located with the thing it monitors is blind to the thing it most needs to catch.
- ❌ No backend/DB failover → nothing to fail over to.
- ❌ No external uptime monitor on the origin specifically (MON-01 still open).
- ⚠️ Initial billing red-herring cost a few minutes (top-up + reboots) before `/account/status` disproved it; the reboots were harmless but useless against a provider network outage.

## Corrective actions

Tracked in [roadmap.yaml#NL-RED-01](../roadmap.yaml) and designed in
[ADR 0012](../decisions/0012-nl-redundancy-warm-standby.md). Headlines:

1. **Warm standby backend+DB off Timeweb** (Hetzner Helsinki) with Postgres streaming
   replication — the real SPoF fix. (needs a standby host provisioned — human-gated)
2. **MSK nginx upstream failover** (`NL primary + standby backup`) — auto-fail RU API.
3. **External off-Timeweb health+balance monitor** on GRA → TG (closes the
   monitor-on-the-monitored-box gap + MON-01).
4. **Verify Timeweb autopay (SBP)** + balance alarm (`hours_left<72`).
5. **B2 restore drill** — prove the documented DR path actually works.
6. **CF Load Balancing** origin failover for the apex (admin/landing) so 522 doesn't recur.

## Lessons (durable)

- A stuck `*_rebooting` that won't complete + 100% loss from all vantages → **suspect a
  provider incident first**; check the provider status channel BEFORE rebooting or
  ticketing. A ticket doesn't speed up a known mass incident.
- The health monitor must live **off** the host it watches.
- One provider holding both the backend AND the RU relay = correlated failure surface.
