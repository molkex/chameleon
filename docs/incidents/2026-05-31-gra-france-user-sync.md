---
title: GRA France exit dead — missing live user-sync
date: 2026-05-31
status: resolved
tags: [incident, vpn, gra, france, user-sync]
---
# 2026-05-31 — France (GRA) exit dead for post-bake users: missing live user-sync

**Severity:** P0 (user-facing — 🇫🇷 France exit unusable on live 1.0.28)
**Status:** RESOLVED 2026-05-31 (backend deploy, no app build)
**Components:** backend `cluster.RelayUserSyncer`, GRA sing-box User API, `vpn_servers.user_api_url`

## Symptom

User on live 1.0.28 selected 🇫🇷 France: the "Напрямую" (VLESS Reality) leg
showed RED/dead, "Hysteria2" pinged ~117 ms but carried no real traffic. NL
(Нидерланды) worked fine.

## Roadmap hypothesis (WRONG)

`roadmap.yaml#GRA-PARITY` blamed a **Hysteria2 Salamander obfs PSK mismatch**
(global `Hysteria2ObfsPassword` plumbed into every H2 outbound). Diagnosis
disproved this:

- NL and GRA Salamander obfs PSK are **identical** (sha256 `1bd96aeb…`). H2
  obfs was never the cause. The 117 ms "ping" is the urltest QUIC handshake
  probe (open port), not authenticated throughput.
- A real end-to-end traffic test through `gra1` (sing-box client on NL → gra1
  VLESS Reality → `ifconfig.me`) returned **54.38.243.162** — i.e. Reality
  handshake + user auth + France egress all work for a *baked* user. The
  Reality leg itself is sound (pubkey `ruI9…` in DB matches GRA's private key,
  short_ids match, egress is IPv4 via `default_domain_resolver: ipv4_only`).

## Root cause

GRA was brought up (2026-05-30) by **baking** NL's then-current user set into
its sing-box config (287 users). New users registered after that bake — and
users whose device account was freshly minted (e.g. the ACCT-IDENTITY anon-
demotion bug) — were **never propagated to GRA**.

The backend only live-synced users to:
1. the **co-located NL** sing-box (`SingboxEngine.userAPI`, 127.0.0.1:15380), and
2. **role='relay'** nodes (`RelayUserSyncer`, e.g. MSK).

GRA is `role='exit'` and not co-located, so it fell through the gap. Its User
API (`127.0.0.1:15380`) was running but unreachable from NL. Result: a
post-bake user dialing gra1 gets a silent Reality reject → dead direct leg;
the H2 leg's password (= user UUID) is likewise unknown → no traffic.

## Fix (backend, no app build — clients refetch /config)

1. **Backend** — generalised `RelayUserSyncer` to also push the active VLESS
   Reality user set to **remote exit nodes**:
   - `db.ListActiveRemoteExitServers()` — exits with `user_api_url IS NOT NULL`.
     The co-located NL exit keeps `user_api_url` NULL (managed locally) → it is
     never a sync target of itself.
   - `PushAll` now loops those exits and bulk-PUTs to inbound `vless-reality-tcp`
     (Reality is primary; H2 users are config-baked, not User-API-managed).
   - Same event-driven (`ReloadVPNEngine` on each user mutation) + periodic
     (30 s) machinery as relays. Unit tests in `cluster/relay_test.go`.
2. **GRA infra** — rebound the sing-box User API `127.0.0.1:15380 → 0.0.0.0:15380`
   (`sing-box check` validated before restart; original backed up), `ufw allow
   from 147.45.252.234 to :15380/tcp` (NL only) + bearer (`USER_API_SECRET`).
3. **DB** — `vpn_servers.user_api_url = http://54.38.243.162:15380` for `gra1`.
4. **Config** — `relay.secrets.gra1 = ${USER_API_SECRET}` (GRA's User API secret
   equals NL's local `USER_API_SECRET`, sha `5da1b561…`). No deploy.sh change
   (USER_API_SECRET already in the container .env).

## Verification

- GRA live runtime VLESS user count converged **287 → 182** = NL's active set
  (the bulk replace prunes stale + adds missing).
- End-to-end traffic test through gra1 with a **current-active** user
  (`357a1bc2…`) → exit IP **54.38.243.162** (France).
- NL → GRA `:15380` reachable (TCP + HTTP 401 without bearer); was timeout
  before the rebind.

## Follow-ups

- **Hysteria2 leg on GRA still baked-only** — H2 users aren't User-API-managed
  anywhere (the User API service only lists `vless-reality-tcp`). New users' H2
  leg on GRA lags until a re-bake. Reality is primary, so the user-facing leg
  works; H2 parity is a separate task (manage H2 inbound via User API, or
  periodic re-bake).
- The same syncer path now covers any future remote exit — set its
  `user_api_url` + add a `relay.secrets.<key>` entry.
- ACCT-IDENTITY (the anon-demotion bug) created some of the unsynced device
  accounts; fixing it reduces churn in the synced set.
