---
title: Production stability audit — client, relays, control plane
date: 2026-07-11
status: active
tags: [audit, production, vpn, ios, relays, reliability]
---

# Production stability audit — 2026-07-11

## Scope and method

Read-only audit of the iOS client, backend, admin SPA, public routes, and the
WAW/GRA/MSK/NL/SPB mesh. Evidence was collected from public HTTP/TCP probes,
read-only SSH/DB/log inspection, App Store Connect API, source review, and the
canonical verification commands. No production configuration or application
code was changed.

## Executive finding

The intermittent user experience is real and has multiple independent causes.
The largest currently measured symptom is iOS connection failure in the public
build; the largest network cause is a TCP-reachable but application-unusable
SPB fallback relay. Stale topology/release state makes incident response and
fallback selection materially less reliable.

## Live checks

| Surface | Result | Evidence |
|---|---|---|
| Public API | Healthy | `https://api.madfrog.online/health` returned 200 with `db=ok`, `redis=ok`. |
| Landing/admin SPA | Reachable | `https://madfrog.online/health` and `/admin/app/` returned 200. |
| WAW | Healthy | `chameleon-failover`, Postgres, Redis, nginx and sing-box were running; local health returned 200. |
| GRA | Healthy at container level | sing-box running; no failed systemd units. |
| MSK | Healthy | nginx points `api.madfrog.online` and `ads.adfox.ru` to WAW:8000; no failed units. |
| WAW → NL replica | Streaming | WAW `pg_stat_replication` and NL `pg_stat_wal_receiver` both reported `streaming`. |
| SPB TCP | Reachable only | 443, 2096, 2098, 2099 and 8443 accepted TCP. |
| SPB API fallback | Failed | HTTP to SPB `:80` for `/api/v1/mobile/healthcheck` timed out after 12 seconds. |
| SPB RU auth decoy | Failed | TLS to `ads.adfox.ru` resolved to SPB `:8443` timed out during handshake. |

Authenticated admin actions were not exercised: a test admin identity was not
created and no production data was mutated. The SPA delivery/build was checked.

## Confirmed findings

### P0 — Public build has a high measured VPN-connect failure rate

Production `app_events` for the preceding seven days:

| App build | Starts | Successes | Fail events |
|---|---:|---:|---:|
| 1.0.27 (90) | 112 | 108 | 9 |
| 1.0.32 (113, public) | 57 | 25 | 30 |
| 1.0.33 (123, TestFlight) | 10 | 8 | 2 |

For 1.0.32, 28 failures have `reason=rejected, stage=watchdog`; two are
`NEVPNErrorDomain Code=5 permission denied`. The event counts may include
multiple attempts per user, but they still demonstrate that the current public
build's connection path is not stable. The TestFlight sample is too small to
claim a fix.

### P0 — SPB fallback/second decoy is TCP-open but application-dead

The repo mirror at `infrastructure/spb-relay/` still routes its API fallback
to NL (`147.45.252.234:80`), despite the NL backend being stopped after WAW
became primary. The public SPB probes timed out for both the API fallback and
the second RU login decoy. SSH to SPB timed out during banner exchange, so the
live configuration could not be read safely.

This is a direct explanation for an RU-specific intermittent path: a client
can establish a TCP connection to SPB but then fail during the real API or TLS
operation. Treat SPB as unhealthy until end-to-end probes pass, rather than
using open-port checks as its health signal.

### P1 — NetworkExtension start/stop race

`PacketTunnel/ExtensionProvider.swift` starts sing-box in an untracked global
GCD task while `stopTunnel` concurrently stops the same service. There is no
lifecycle generation, cancellation, or final-state guard. A rapid user/OS
stop can therefore race a late successful start and publish an incorrect
connected state.

### P1 — VPN profile selection is nondeterministic

`VPNManager` and `VPNControlIntents` use the first value returned by
`loadAllFromPreferences()` without identifying the intended provider profile.
Devices with legacy/multiple profiles can observe or control the wrong tunnel.

### P1 — Connect UX exceeds the project deadline

`AppState.awaitConnectionWithSilentRetry` performs an 18 second wait, up to 3
seconds of teardown, a one second delay, and another 18 second wait. The
worst-case error is about 40 seconds, violating the project requirement to
disconnect and present an error within 30 seconds.

### P1 — Release and topology state are stale/contradictory

App Store Connect verifies `1.0.32 (113)` as `READY_FOR_SALE`; 1.0.31 and
1.0.30 are also ready for sale. `state/app-store.yaml` still claims 1.0.28
(91) as current, while `project.yaml` says 1.0.32 is waiting for review.

`state/servers.yaml` marks NL offline and replication absent, but direct
inspection found NL reachable with an active streaming receiver. It also
correctly remains true that the NL API backend is stopped. These contradictions
make operations, support diagnosis, and fallback configuration unsafe.

### P1 — Non-renewing StoreKit products can appear active forever

All four products in `MadFrogVPN/Products.storekit` are
`NonRenewingSubscription`. `SubscriptionManager.isActiveEntitlement` treats
any known, unrevoked entitlement with `expirationDate == nil` as active. The
unit tests explicitly assert that invariant for all four products. `AppState`
then accepts `isPremium` as sufficient to allow a connection.

This is an authorization/revenue risk. It must be corrected and validated with
a StoreKit sandbox transaction after the intended backend expiry; it is not
being presented as a completed device-level reproduction.

### P1 — Alternate VPN entry points bypass the app gate

Widget/Shortcuts intents start a tunnel directly and the reconnect action
calls `toggleVPN` rather than `requestToggle`. The normal subscription gate is
therefore not the sole entry point. Server-side expiry must remain authoritative
and the client must share one gated start path.

### P2 — API fallback still includes retired backend capacity

`Shared/Constants.swift` retains NL/direct legacy API entries while WAW is the
primary backend. This spends race/fallback budget on a backend that is known
not to serve the API and makes diagnostics misleading.

### P2 — Sensitive request content can enter support diagnostics

On direct-leg non-2xx responses, `Shared/Networking/DirectConnection.swift`
logs request previews and response bodies. These can contain bearer or refresh
credentials and diagnostic logs are available to support workflows. Redact
authorization headers, tokens, and bodies before collecting more user logs.

## Why this feels intermittent

The core WAW API and two exit nodes were healthy at audit time. Failures occur
at boundaries: a selected SPB relay accepts TCP but fails API/TLS; connection
watchdog/lifecycle behavior produces client-side rejected attempts; and users
on the public build do not yet have the later TestFlight DNS-stall and relay
recovery changes. Different carrier, route, saved VPN profile, and app build
therefore produce different outcomes for the same user action.

## Verification performed

```text
cd backend && go test ./... -count=1                  # PASS
cd clients/admin && npm run test:run && npm run lint && npm run build
                                                      # 22 tests PASS; lint 0 errors, 12 warnings; build PASS
cd clients/apple && xcodegen generate && xcodebuild build -scheme MadFrogVPN \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
                                                      # BUILD SUCCEEDED
```

The local iOS Simulator cannot be used for runtime verification: its
CoreSimulator framework is older than the installed Xcode expects. This does
not affect the device-target build result.

## Recommended remediation order

1. Restore SPB management access; compare its live nginx configuration with
   the repo mirror; point every API/decoy route at WAW; verify from an RU
   network with real HTTP and TLS probes. Do not declare SPB healthy from TCP
   alone.
2. Fix the NetworkExtension lifecycle as a single serialized state machine,
   add a start/stop-race regression test, and enforce a total connect deadline
   below 30 seconds.
3. Ship a verified post-123 release; validate connection, RU authentication,
   Instagram/DNS traffic, reconnect, expiry/paywall, and country selection on
   a physical iPhone before submission.
4. Make the backend entitlement authoritative for every VPN entry point; fix
   the non-renewing entitlement interpretation and test expiry explicitly.
5. Refresh `state/servers.yaml`, `state/app-store.yaml`, and client fallback
   constants from verified facts. Add synthetic end-to-end monitors for MSK
   and SPB API/decoy routes, plus an alert on high watchdog rejection rate.

## Addendum (2026-07-11, later same day): the 6 stuck devices, root-caused

Same-day follow-up, after the HA-drill work (see
[2026-07-11-ha-drill.md](../incidents/2026-07-11-ha-drill.md)) reactivated
NL's `nl2` VPN exit and SPB was separately recovered. Pulled the full detail
on the 6 devices responsible for 28 of the 30 `vpn.connect.fail` events on
1.0.32(113) (the P0 finding above):

- All 6 are **brand-new trial installs** (install dates 2026-05-30 through
  2026-07-10) — first-session failures, not established users regressing.
- Breaking their `vpn.connect.start` events down by selected server: 40 on
  "Auto", 4 on France (GRA), 4 on direct-Poland, and **5 explicitly on
  "🇳🇱 Нидерланды"** — the NL/`nl2` exit, which was **deactivated in the
  database for the entire failure window** and was only reactivated live as
  part of today's HA drill. Those 5 attempts were guaranteed to fail
  regardless of any client code — you cannot connect to a deactivated exit.
- The remaining ~44 failures (mostly "Auto") fall in the same window SPB
  was confirmed fully dead (TCP-open, application-unresponsive) — SPB was
  only paid-for and recovered today, in this same session.
- Checked whether "routed via MSK relay" (RU) distinguished the failing
  cohort from everyone else: it doesn't — **100% of `vpn.connect.start`
  events across every app version** show the MSK relay as source, meaning
  the entire current active user base is RU-routed. Not a useful
  discriminator on its own; install recency and explicit dead-exit
  selection are.

**Read on the P0/P1 client bugs above, given this:** the entitlement gate
bug (still P0) was never a candidate cause of these failures — it errs
permissive (lets people connect who shouldn't), unrelated to connect
*failures*. The NE start/stop race and the sub-30s-deadline violation are
real and still worth fixing, but most likely *shaped* these failures (a
~40s hang instead of a clean sub-30s error) rather than *caused* them — the
`reason=rejected, stage=watchdog` pattern on all 28 events is exactly what a
client racing onto a dead exit/relay leg produces. Don't expect fixing the
NE race alone to move the connect-success number; the dead legs were very
likely the dominant cause, and two of them (`nl2`, SPB) were fixed today as
an unplanned side effect of unrelated HA-redundancy work.

**Not yet measured:** no post-fix field data exists yet (SPB/nl2 fixed only
hours before this addendum was written). Recommended before drawing a firm
conclusion: (1) treat the next successful explicit-NL connect as direct
causal confirmation (n=1 is enough — the prior rate was structurally 0%);
(2) watch new-install first-session connect-success going forward as the
real trial-funnel metric; (3) build the SPB/MSK synthetic monitor from
remediation item 5 above with real urgency — SPB died silently for an
unknown number of weeks because its only health signal was "TCP still
open," and it will do so again without one.
