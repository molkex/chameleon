---
title: Structure + test-coverage + hygiene audit (4-agent)
date: 2026-06-26
status: living   # action plan; tick items as done
tags: [audit, docs, tests, architecture, hygiene, security]
supersedes_for_servers: [2026-05-26-gpt-servers-audit, AUDIT_SERVERS_2026-05-26_GEMINI]
---

# 2026-06-26 — Structure / Test / Hygiene audit

4 parallel sub-agents audited: (1) docs structure & YAML/MD discipline, (2) test
coverage vs `state/test-map.yaml`, (3) codebase architecture map vs CLAUDE.md, (4)
code hygiene + security. This doc is the synthesis + the prioritized action plan.
Tick items here as they land; move completed structural items into `roadmap.yaml#done`.

## Verdict (headline)

- **Docs format split (decision 0006) is CORRECT** — YAML=state, MD=narrative. The
  problem is NOT format; it's **stale state, bloat, and doc↔code drift**. Do NOT convert
  narrative MD to YAML.
- **Tests are GREEN** — backend all packages pass (`go test ./...`), admin 22/22 vitest.
  But the **money-in HTTP handlers have ZERO handler-level coverage** (highest risk).
- **One CRITICAL doc-vs-reality bug:** CLAUDE.md says the VPN server is "Xray 25.12.8",
  but every exit (NL + GRA + new WAW) actually runs **`sing-box-fork:v1.13.6-userapi`**.

## A. State docs — stale facts (P1, fixed this session)

| Item | Was | Fix |
|---|---|---|
| `state/app-store.yaml` | current=1.0.28/91 (25 days stale) | → 1.0.30 live / 1.0.31 / 1.0.32 / 1.0.33 |
| `state/project.yaml#now` | 2026-06-04 handoff | → current (maturity-loop + NL outage + WAW) |
| `state/project.yaml#recent` | ~130 lines of shipped narrative | trim → pointer to roadmap#done + audits |
| `state/servers.yaml` | no WAW | + WAW (OVH Warsaw 217.182.74.70) |
| `state/runtime.yaml` | no GRA, no WAW (verified 2026-06-01) | + GRA + WAW container maps |

## B. Test coverage — drift + gaps

**test-map.yaml drift (doc-only fixes):** geoip 36→87%; `storage`/`secrets` YAML merge bug
(storage is 39.5% not 80%, secrets is 80.5%); add missing pkgs `lifecycle` (50.5%),
`promo` (72.4%), `push` (30.7%); admin tests 10→22; add iOS `PlanPricing`/PlanPricingTests;
`meta.updated`→2026-06-26.

**Real coverage GAPS (tracked as roadmap testing items):**
| Pri | Gap | File | Risk |
|---|---|---|---|
| P1 | FreeKassa webhook + initiate/status handler glue (sig layers tested in pkg, handler NOT) | `api/mobile/payment_webhook.go`, `payment.go` | money-in, replay→double-credit |
| P1 | Apple `VerifySubscription` handler (pkg 74% tested, handler NOT) | `api/mobile/subscription.go` | money-in / IAP fraud gate |
| P2 | `GetConfig` handler (predicate tested, full handler NOT) | `api/mobile/config.go` | core VPN delivery — silent break |
| P2 | magic-link token gen/validate/expiry | `api/mobile/auth_magic.go` | auth/token forgery |
| P2 | admin dashboard/nodes handlers | `api/admin/nodes.go` (1235 loc) | ops visibility |
| P3 | lifecycle Sweep, push Send, admin SPA page render, Apple JWS chain | various | low (mostly tracked) |

→ New roadmap items: TEST-PAYMENT-WEBHOOK (P1), TEST-APPLE-SUBSCRIPTION-HANDLER (P1),
TEST-MOBILE-CONFIG-HANDLER (P2). Pattern: httptest + echo ctx + mocked seam (no real JWS/DB).

## C. Architecture doc ↔ reality (CLAUDE.md corrections, fixed this session)

1. **CRITICAL:** "Xray 25.12.8 server" → exits run **`sing-box-fork:v1.13.6-userapi`**
   (`backend/scripts/singbox.env`, `vpn/userapi.go`). `arch/vpn.md` is already correct;
   CLAUDE.md "Стек" + "important rules" were wrong. (The `mux`-vs-Xray + "NOT v26" warnings
   are legacy and misleading — clarify.)
2. Apple targets "4 штуки" → **5** (incl. MadFrogWidget).
3. Servers table missing **WAW**; add it.
4. `Ключевые файлы` omits: `vpn/singbox.go`, `vpn/userapi.go`, `cluster/`,
   `vpn/clientconfig_fingerprint.go`; iOS `SingBoxConfigPatcher`, `LegRaceProbe`,
   `RealTrafficStallDetector`, `TrafficHealthMonitor`, `CommandClient`.
5. Admin API field `xray_version` + `/restart-xray` route → rename to singbox (keep alias).

## D. Hygiene + security (tracked in roadmap)

| ID | Pri | Finding | Fix |
|---|---|---|---|
| H-01 | P1 sec | `InsecureDelegate` accepts any cert on direct-IP race legs (APIClient.swift) | pin fingerprint via /server/info (= existing TD-CERT-PIN) |
| H-02 | P1 sec | `subscription_token` replicated to GRA exit in cluster sync (`cluster/models.go`) — exit doesn't need it | strip from SyncUser/SyncedUser |
| H-03 | P1 sec | `/sub/:token` credential-in-URL route alive (`server.go:259`) | grep nginx logs on NL; delete if dead |
| H-04 | P1 | `health-check.sh` runs ON NL → silent during 2026-06-26 outage | DONE-partial: external GRA monitor live (NL-RED-MON); finish coverage |
| H-05 | P2 | `stderr.log` (libbox C-side) has no Swift cap | cap on startTunnel (LOG-01 remainder) |
| H-06 | P2 | `countryDisplay` duplicated backend↔iOS, drifts (us/ru missing on iOS) | ship display_name in config, drop iOS map |
| H-08 | P2 | `TunnelStallProbe` passive-only since b44, still wakes NE | remove instantiation (AUDIT-DEBT) |
| H-12 | P3 | silent `.disconnected` doesn't surface "another VPN active" | wire anotherVPNActive() into handleStatus (= UX-VPN) |
| H-09/10/11/14 | P3 | watchdog default 30s; DE-IP test sentinel; app_events dynamic-SQL look; country map sync | per table |

Note: `backups/` local DB dumps are **gitignored** (not committed) — no PII leak. ✅

## E. Structure reorg (P2/P3 — partial this session, rest next)

- Archive superseded (no live links): `audits/2026-05-26-gpt-full-audit.md`,
  `2026-05-26-gpt-servers-audit.md`, `AUDIT_SERVERS_2026-05-26_GEMINI.md`,
  `2026-05-30-internal-audit.md`; `plans/support-chat-p0.md`; `plans/*.html` → `archive/2026-0X/`.
- `arch/target.md` + `arch/mesh.md` (aspirational/historical) → archive, keep stubs/links.
- Add front-matter to 13 files missing it (6 incidents, 2 decisions, 5 release-notes, audits).
- **Token bloat:** `roadmap.yaml` (2313 lines) — trim `done` entries to id+date+one-liner
  (full narrative already in incidents/audits); `project.yaml#recent` → pointer. ~1800 lines saveable.
- Add `docs/arch/repo-map.md` (the area-by-area code map) for instant "what is where".

## Priority order for next session

1. (P1 tests) TEST-PAYMENT-WEBHOOK + TEST-APPLE-SUBSCRIPTION-HANDLER — money paths, no build needed.
2. (P1 sec) H-02 strip subscription_token from cluster sync + H-03 audit /sub/:token — server-only.
3. (when NL back) finish WAW: register exit + user-sync + clientconfig → Poland for all users; Postgres replication.
4. (P2) roadmap done-trim + structure archive + front-matter + repo-map.
5. (rides next iOS build) H-01 cert-pin, H-05 stderr cap, H-08 TunnelStallProbe, H-12 UX-VPN, H-06 countryDisplay.
