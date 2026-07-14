---
number: 0014
title: Harden under invariants, do not rewrite
date: 2026-07-15
status: accepted
supersedes: none
---

# 0014 — Harden under invariants, not a rewrite

## Context

After a week of P0 incidents (the NE OOM reset-loop and its 45→48 MB sequel, placebo
UI controls, a dead relay still selectable, the `smart` routing design error), the
owner asked for "правильная архитектура, чтобы не было проблем в дальнейшем — акцент
на простоту и надёжность." The literal reading is "rewrite it properly." Two
independent analyses (the assistant's, and a separate architect pass) reached the
same verdict, which is why this is recorded as a decision rather than a suggestion.

## Decision

**Do not rewrite.** Not the client, not the NetworkExtension, not the backend. Adopt
a small set of enforced invariants and execute deletion. Exactly one subsystem gets a
targeted re-architecture: **collapse the four server-selection systems into one.**

### Why not a rewrite

1. **The core was never the problem.** Every P0 lived in accretion layers — config
   decoration, redundant health systems, UI toggles wired to nothing. libbox + VLESS
   Reality + the Go backend + payments + auth have been stable for months. A rewrite
   rebuilds the healthy 80% to fix the sick 20%.
2. **The constraints don't change.** A greenfield client still gets ~50 MiB in the NE,
   still faces RKN filtering, still ships the same libbox fork, still can't run unit
   tests in an unsigned sim. A rewrite discards the repo's most valuable asset — its
   accumulated incident knowledge, encoded in comments and pinned tests.
3. **The economics forbid it.** ~€45/quarter revenue, ~€28/mo infra, ~2 tunnel
   devices/week. A solo-dev rewrite is months of zero shipping plus a regression tail.
4. **The codebase already knows how to delete** — Calm theme (−700 LoC), `refilter`,
   `smart`, `LegRaceProbe` were all removed recently and all made things better.

The one place hardening is insufficient is server selection: four components make
switching decisions today (sing-box urltest, the NE stall detector, the app-side
`TrafficHealthMonitor` cascade, and the `PathPicker`/`LeafRanking` stack), and they
fight. That subsystem is replaced by subtraction, not refactoring.

## The invariants

- **I-1 — NE memory budget ≤ 35 MiB steady-state; ordering pinned.** Always
  `Go soft cap < oom backstop < jetsam` (today 45 < 48 < 50). Nothing in the NE
  fetch-and-parses a remote asset at tunnel start. The trip metric is whole-process
  `phys_footprint`, not the Go heap — any `memory_limit` must stay above the Go soft
  cap (this is the 45 MB regression, pinned by `TestOOMKillerServiceHasExplicitMemoryLimit`).
- **I-2 — Tunnel bring-up needs zero reachable hosts except the exit.** A valid cached
  config must connect on a maximally hostile RU network. Violated today by the blocking,
  fatal `geoip-ru.srs` fetch from GitHub raw → bundle it locally.
- **I-3 — One source of truth for config.** The backend emits the final config; the
  client injects only device-local state (routing-mode bake, local-rule-set rewrite,
  a versioned compat shim that logs every rewrite). No more silent backend-vs-sanitizer
  disagreement.
- **I-4 — One selection authority: sing-box urltest inside the tunnel.** The only
  vantage that sees real traffic. The app expresses user intent only (one selector PUT).
  The NE stall detector *triggers* an early re-probe; it never selects. After migration,
  `selectOutbound` has exactly two callers.
- **I-5 — No control ships without proven wiring; no dead infra is user-selectable.**
  Every toggle maps to a named effect with a test or a release-checklist verify step.
  Anything in the picker is `is_active=true`; dead infra is removed in the DB, never
  worked around in client code.
- **I-6 — Every network op has a deadline; connect ≤ 30 s end-to-end.** Hedged race
  legs pass a *definitive* win policy (a fast wrong answer must not beat a slow right one).
- **I-7 — Facts live in `docs/state/*.yaml`; anything repeated elsewhere is a pointer.**
  (The "CLAUDE.md listed a decommissioned exit as live" drift.)
- **I-8 — Every code change ships a test or logs a `TEST-*` gap** (decision 0009, kept).

## Migration path (small, reversible, ordered by reliability-per-effort)

**Phase 0 — no client build, ~1 day:** SPB dead legs `is_active=false` (done
2026-07-14); urltest `interval` 10s→120s + explicit `tolerance:150` (highest-value
item, reaches every user without an App Store cycle); re-confirm the 48MB/60s oom
backstop is live; prune MSK stale `vless-de` leg.

**Phase 1 — client build 1.0.35, "NE diet":** bundle `geoip-ru.srs` (I-2); delete
`TunnelStallProbe`'s probe loop + per-probe URLSession leak (keep `nudgeNow`); delete
the inert GOMEMLIMIT `setenv` block; remove dead SPB/fallback hosts from `Constants.swift`.
Release-gate on before/after device memory numbers during a Telegram media download.

**Phase 2 — selection consolidation (the one re-architecture):** Build A puts the
app-side cascade behind a default-OFF flag, observe one TestFlight cycle; Build B
deletes the cascade + `PathPicker` + `LeafRankingStore` + `LastWorkingLegStore` +
fingerprinting (~1.5–2k LoC). One selection authority remains.

**Phase 3 — config contract:** backend emits final values; sanitizer shrinks per I-3;
golden contract test + dockerized `sing-box check` in backend CI.

**Phase 4 — fork + memory floor (only after 0–2 measured):** rebase `service/oomkiller`
onto current upstream (disarm fix + hysteresis); lower Go soft cap to ~37 MiB, keep
37 < 48 < 50; never tune blind.

**Phase 5 — mesh hygiene:** SPB recover→instrument→data-decide; `deploy.sh waw` +
`WAW-SINGBOX-VOLUME` fix; controls-inventory table + 10-minute device smoke checklist.

## What NOT to do

No rewrite. No new exits until >2 devices/week use the tunnel. No Hysteria2/TUIC
expansion or port-hopping (solves a problem we don't have). No auto-failover watchdog
(manual promotion at ~2.5m RTO is correct at this scale). No third routing mode without
an ADR answering "what happens to bare-IP flows and far-side geo-blocks" (the two
classes that killed `smart`). No memory-relevant NE change without a before/after device
measurement. No new client-side health/selection logic (I-4 exists to make the fifth
layer unthinkable). Feature work stays paused per the 2026-07-11 decision.

## Consequences

The detailed, file-cited version of this plan (subsystem budgets, exact deletion
targets, the testing strategy) is the operational companion to this ADR; the executable
items live in `roadmap.yaml#next.client_reliability` (SIMP-01…06, which this ADR
operationalizes). Phases 0–1 alone remove the connection-tearing urltest churn, the
GitHub-raw start dependency, the NE native leak, and the dead-host dials — most of
"работает через раз" as currently understood.
