---
title: Network mesh & relay stability audit — WAW/NL/GRA/MSK/SPB
date: 2026-07-11
status: active
tags: [audit, production, infra, relays, hosting, reliability]
related: [2026-07-11-production-stability-audit.md]
---

# Network mesh & relay stability audit — 2026-07-11

## Scope and method

Read-only, live diagnostics of the server mesh (WAW, NL, GRA, MSK relay, SPB
relay) plus external HTTPS/DNS probes of the public-facing surface, run in
parallel by 4 independent agents (SSH + `docker`/`systemctl`/log inspection +
`curl`/`dig` from outside). No production configuration or code was changed.
This is the infra counterpart to
[2026-07-11-production-stability-audit.md](2026-07-11-production-stability-audit.md)
(client code, entitlement, telemetry) — read both together. Where the two
overlap (SPB), findings are cross-referenced rather than duplicated.

## Headline

Core control plane (WAW backend/DB/Redis, MSK→WAW ingress, Cloudflare,
admin SPA) is healthy and not flapping: zero firing Prometheus alerts, zero
real 5xx in nginx/app logs, no resource pressure on any of the three primary
boxes. The intermittency users feel comes from the edges, not the core:

1. **SPB relay is host-level dead** (TCP handshake succeeds, zero
   applicationdata ever returns — consistent with a DDoS-protection SYN-proxy
   answering for a hung box). Confirms and complements
   `2026-07-11-production-stability-audit.md`'s finding that SPB's *config*
   also still points at NL's dead backend — both are true and both need
   fixing; fixing only the config will not bring SPB back if the host itself
   is unresponsive.
2. A stale relay leg on MSK (`vless-de :2096`) still points at the retired DE
   box — a silent black hole for any client with a cached config that offers it.
3. A legacy domain alias (`razblokirator.ru`) is 100% broken (headers arrive,
   body never does).
4. Two real, already-resolved hosting incidents in the last 72h (OVH
   hypervisor reset on WAW, Timeweb reboot-flapping on NL) explain specific
   past outage windows and confirm the underlying hosts are not yet on solid
   ground even though they're healthy right now.
5. A quantitative read on `2026-07-11-production-stability-audit.md`'s
   telemetry claim: the 30 `vpn.connect.fail` events on build 1.0.32(113) in
   7 days come from only **6 distinct devices out of 10 total active on that
   build** — a concentrated failure in a small stuck cohort, not a uniform
   ~50% failure rate across the public build's user base. Narrows where to
   look next (see "Telemetry re-check" below).

## Live checks

| Surface | Result | Evidence |
|---|---|---|
| WAW containers (failover/postgres/redis/nginx/monitoring) | Healthy | All 8 containers Up 2d; healthcheck `{"db":"ok","redis":"ok","status":"ok"}` every 10s, 0 FailingStreak |
| WAW `docker logs` | Broken (cosmetic) | NUL bytes from the Jul-8 unclean reset break json-log decoding; raw log file confirms 0 error-level lines, 0 5xx since Jul 9 |
| WAW → NL replication | Streaming | `pg_stat_replication`: `state=streaming`, slot `nl_standby`, replay lag ~0; NL `pg_stat_wal_receiver` confirms `status=streaming` |
| WAW resources | Healthy | disk 5% used, RAM 778Mi/11Gi, load 0.00, Prometheus `alerts: []` |
| NL reachability | Recovered | SSH/443 both answer; `chameleon`/`chameleon-nginx` correctly Exited (replica design); `pg-tunnel-waw.service` active since Jul 10 01:39 UTC |
| GRA container | Healthy | sing-box-fork up 2d, User API :15380 syncing roster (`9 users`) every ~30s |
| GRA direct REALITY from RU | Degraded | ~15,259 `REALITY: processed invalid connection` lines/48h from RU residential IPs hitting GRA directly; same IPs succeed via MSK relay chains |
| MSK nginx upstream | Correct | `api.madfrog.online` and the `ads.adfox.ru` decoy both `proxy_pass` to WAW:8000; 0 502/504 in access logs; e2e `/health` 200 in 0.136s |
| MSK relay chains | 2097 (nl) / 2099 (fr) alive, **2096 (de) stale** | `vless-de :2096 → wg-de → 162.19.242.30` (retired 2026-05-25) still configured and listening |
| SPB reachability | Half-open | TCP connects on 22/80/2098/2099/8443; SSH hangs at banner exchange; HTTP/raw reads return 0 bytes and time out on every port tested, from both outside and from MSK |
| External: madfrog.online, /admin/app/, api.madfrog.online/health, mdfrog.site | Healthy | 200s, sub-second latency; api/health: 15/15 200 across burst + spaced probes, zero variance |
| External: razblokirator.ru | Broken | Cloudflare returns HTTP/2 200 headers, body never arrives — 0 bytes, 4/4 attempts, 15-20s timeout |
| DNS | Correct | `api.madfrog.online` → MSK 217.198.5.52; apex + aliases → Cloudflare → WAW; no stale NL/DE IPs found in DNS |

## Confirmed findings

### P0 — SPB relay is unresponsive at the host/network-stack level

`185.218.0.43`. TCP handshakes complete on every probed port (22, 80, 2098,
2099, 8443) but no application data is ever returned — not just on the API
fallback port (`:80`, cross-referenced in
`2026-07-11-production-stability-audit.md`) but also on `:2099`
(`ru-spb-fr`, which proxies straight to GRA and has nothing to do with the
dead NL backend). This rules out "it's just misconfigured to point at NL" as
the sole explanation — the box itself is not answering. The pattern (SYN
accepted, zero bytes, everything times out including SSH banner exchange) is
consistent with the hosting provider's DDoS protection holding the TCP state
for a host that is otherwise hung or unreachable behind it.

**Impact:** SPB backs two RU-facing paths — the second sign-in decoy leg
(RU-DECOY-2ND) and the `ru-spb-nl`/`ru-spb-fr` whitelist-bypass VPN chains.
Both were built specifically to remove a single point of failure for RU
users; with SPB dead in this "hangs instead of failing fast" way, any
multi-leg race that includes it now *waits out a full timeout* instead of
falling over quickly to a working leg — this is a strong candidate for part
of the "sometimes works, sometimes doesn't" symptom, especially for RU users.

**Fix:** recover the box via the SprintHost control panel (SSH is
unavailable for config inspection); once reachable, verify the SPB→WAW
upstream fix from `2026-07-11-production-stability-audit.md` is also
applied — both layers need to be right.

### P1 — Stale MSK relay leg still points at the retired DE server

`217.198.5.52`, port `2096` (`vless-de` chain) forwards to `wg-de` →
`162.19.242.30` — the DE box retired 2026-05-25. This is exactly the class of
bug CLAUDE.md already warns about ("DE retired — не упоминать
162.19.242.30"), just found live in a relay chain config rather than in
docs/code. Any client that still carries this leg in a cached config (old
install, or a config fetched before the leg was pruned client-side) hits a
silent dead end with no fallback signal.

**Fix:** remove the `vless-de`/2096 chain from MSK's sing-box config if no
active client references it (check MSK connection logs for any traffic on
2096 first, to confirm it's actually dead weight and not still serving a
long tail of stale clients).

### P1 — razblokirator.ru is 100% broken (headers arrive, body never does)

Reproduced 4/4 times: Cloudflare returns a 200 with normal headers
(`server: cloudflare`, `cf-cache-status: DYNAMIC`, a `last-modified` from
2026-05-12), then the response body never streams — the connection just
hangs until the client times out (tested at both 15s and 20s). For a real
visitor this is an endless spinner or blank page, not a clean error.

**Fix:** this alias's origin/`server_name` mapping on WAW nginx is likely
incomplete — the other legacy aliases (`mdfrog.site`) serve correctly from
the same Cloudflare setup, so this is specific to `razblokirator.ru`'s
config, not a WAW-wide problem.

### P2 — Two hosting-level incidents in the last 72h, both self-resolved

- **WAW (OVH):** journal ends abruptly (no clean shutdown sequence) at
  2026-07-08 21:26:40 UTC, restarts 21:33:30 — a ~7-minute hypervisor-level
  hard reset, not an OOM or kernel panic (no such traces). If user reports
  cluster around that evening, this explains them. Side effect: NUL bytes in
  the container's json-log break `docker logs` for `chameleon-failover`
  going forward — cosmetic, but worth a container recreate at the next
  planned maintenance window to restore log visibility.
- **NL (Timeweb):** three reboots in ~2.5 hours (2026-07-09 23:13, Jul-10
  00:16, Jul-10 01:39) — the same signature as the 2026-06-26 Timeweb
  outage. Also one brief WAW-unreachability event logged from NL's tunnel at
  2026-07-08 21:28 (`connect to host 217.182.74.70 port 22: Connection timed
  out`), same evening as the WAW reset above — consistent, not two unrelated
  events. NL has been stable for 26+ hours as of this audit and the
  WAW↔NL replica is streaming with ~0 lag.

**Why this matters going forward:** the replica came back on its own, but
the recurring Timeweb reboot pattern (this is the *second* documented
instance) is a signal the underlying host is not reliable long-term. The
still-undone `HA-DRILL` item in `roadmap.yaml#next` (failover.sh has never
been drilled) is the actual mitigation for this class of event and should
not keep slipping.

### P2 — RU direct REALITY connections to GRA are being mass-rejected

~15,259 `REALITY: processed invalid connection` lines in 48h on GRA, from a
small set of RU residential IPs (e.g. `37.113.209.92`, `128.71.141.40`,
`217.73.118.204`) connecting directly. The same IPs connect successfully
through the MSK relay chain (`vless-fr → wg-fr → GRA`) at 30-50ms. This
looks like RKN tampering with direct REALITY handshakes rather than a config
bug, but is worth a quick client-side sanity check (confirm the shipped
`reality_pubkey` matches GRA's current keypair) before writing it off as
purely network-level.

## Telemetry re-check (cross-referencing the client audit)

`2026-07-11-production-stability-audit.md` reports, for the last 7 days on
production DB (`chameleon-postgres-standby` on WAW, table `app_events`):

```
app_version    event_name            count
1.0.27 (90)    vpn.connect.start     112
1.0.27 (90)    vpn.connect.success   108
1.0.27 (90)    vpn.connect.fail        9
1.0.32 (113)   vpn.connect.start      57
1.0.32 (113)   vpn.connect.success    25
1.0.32 (113)   vpn.connect.fail       30
1.0.33 (123)   vpn.connect.start      10
1.0.33 (123)   vpn.connect.success     8
1.0.33 (123)   vpn.connect.fail        2
```

Independently re-ran this query directly against WAW — numbers match
exactly, including the fail-reason breakdown for 1.0.32(113)
(`reason=rejected, stage=watchdog`: 28; `NEVPNErrorDomain Code=5 permission
denied`: 2). Not a hallucination.

Went one step further and grouped by `user_id`/`device_id`:

```
distinct_users_failing (1.0.32/113, 7d) = 6
distinct_devices                        = 6
distinct users with ANY event on 1.0.32  = 10
```

**This changes the interpretation.** The ~53% fail rate on build 1.0.32(113)
is not a uniform coin-flip across that build's user base — it is **6 stuck
devices (out of only 10 total active on that build) retrying repeatedly**,
averaging 5 failures each. That's still a real, serious problem for those 6
users (and consistent with the SPB/stale-leg findings above — a device that
lands on a dead relay leg will retry-and-fail over and over), but the fix
target is narrower than "half of all public users can't connect": it's
"identify what these 6 devices have in common" (country/ISP/selected
relay/cached config) before assuming a blanket client-side fix will resolve
it. Recommend pulling `ip`/`country`/`properties` for those 6 device_ids'
fail events as the next diagnostic step — not done here (out of scope for
this pass, flagging as a follow-up).

## Verification performed

```
ssh debian@217.182.74.70   # WAW — docker ps/logs, pg_stat_replication, resources, nginx logs
ssh root@147.45.252.234    # NL — reachability, pg-tunnel-waw.service, replication receiver
ssh debian@54.38.243.162   # GRA — sing-box status, User API sync, error logs
ssh root@217.198.5.52      # MSK — nginx upstream config, relay chain status, access/error logs
sshpass ssh root@185.218.0.43   # SPB — attempted, timed out at banner exchange (not read)
curl (external)            # madfrog.online, api.madfrog.online, admin SPA, mdfrog.site,
                            # razblokirator.ru, grafana.madfrog.online, TLS cert check, DNS-over-HTTPS
psql (WAW, read-only)      # app_events telemetry re-check + user/device concentration breakdown
```

No destructive commands were run; no service was restarted or reconfigured.

## Recommended remediation order

Merges with `2026-07-11-production-stability-audit.md`'s list rather than
replacing it — see that file for the client-code items (entitlement gate,
NetworkExtension start/stop race, 30s deadline, intent bypass).

1. **SPB** — recover the host (SprintHost panel; SSH is unusable), *then*
   verify/fix its upstream config (API fallback + decoy currently mirror
   points at dead NL) — both layers, in that order, since fixing the config
   first is unverifiable while the host itself doesn't answer.
2. Remove the stale `vless-de`/2096 leg from MSK (after confirming via
   traffic logs it's not still serving a long tail of old clients).
3. Fix `razblokirator.ru`'s origin mapping on WAW nginx.
4. Pull `ip`/`country`/`properties` for the 6 stuck 1.0.32(113) devices to
   find the common factor before shipping a blind client fix.
5. Run the overdue `HA-DRILL` (roadmap `next.audit_2026_06_29`) — two
   Timeweb reboot incidents on NL now, the actual mitigation for this class
   of event is still unexercised.
6. Refresh `docs/state/servers.yaml` / `docs/state/app-store.yaml` per the
   client audit's P1 finding (already flagged there — no need to duplicate
   the fix here, just confirm it covers the NL-reachable-now correction too).
