---
date: 2026-06-03
severity: P3 (metric correctness / operator confusion — no user impact)
component: backend/metrics · admin dashboard
status: fixed + deployed NL (commit d17130d)
related: [TRAFFIC-MULTIEXIT (roadmap now)]
---

# Admin "Active (24h)" reads lower than "Online"

## Symptom
Admin dashboard showed **Online: 35** ("live VPN sessions right now") but
**Active (24h): 16** — logically backwards (everyone online now should count as
active today).

## Why (not a bug — two different systems)
| Card | Source | Meaning |
|---|---|---|
| Online | `VPN.OnlineUsers()` → sing-box clash_api `/connections` (stats.go) | distinct live connection identities in the last **2 min** (`recentUserTTL`), keyed by sing-box `InboundUser` or `SrcIP` |
| Active (24h) | `DB.CountActive24h()` → `last_seen >= NOW()-24h` | users whose **app fetched `/config`** in 24h (touchDevice, config.go:164) |

`last_seen` is bumped **only** on `GET /api/v1/mobile/config`. A VPN is "connect
once, leave it on": the tunnel carries traffic for days while the app caches the
config and never re-fetches → an actively-tunnelling user falls out of the 24h
`last_seen` window but stays in the live sing-box count. Hence Online > Active.

## Fix (commit d17130d, deployed NL 2026-06-03 14:28)
- Migration `019_last_vpn_seen.sql`: new `users.last_vpn_seen TIMESTAMPTZ` + partial index.
- `runTrafficCollector` (main.go) bumps `last_vpn_seen = NOW()` for every user with
  a non-zero traffic **delta** in the 60s interval (`BumpVPNSeen`). Deltas already
  drive `cumulative_traffic`, so this is the real "moved data" signal.
- `CountActive24h` / `CountActive30d` now count active = **app OR VPN**
  (`last_seen OR last_vpn_seen` within window). `last_seen` is left untouched, so
  DAU / retention / funnel (db/funnel.go, metrics RefreshDAU) keep meaning *app
  engagement* — the Prometheus `chameleon_dau_users` gauge is still app-DAU.
- Tests: `users_active_test.go` (integration) — app-OR-vpn count matrix + BumpVPNSeen.

## Verified on prod
`last_vpn_seen` populating within ~2 collector ticks; `active_24h` climbs above
app-only as traffic flows. Ramps over the first ~24h post-deploy, then
Active(24h) >= Online as expected.

## Known residual
Traffic stats are from **NL's** sing-box (relays forward to NL → RU users
covered). **GRA-direct** users (`fr-direct-gra1`) transit GRA's own sing-box and
are not yet captured in either Online or last_vpn_seen — same gap as
TRAFFIC-MULTIEXIT (roadmap `now`). Closing that needs per-node stats fan-out.
