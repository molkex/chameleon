---
title: France relay legs via MSK and SPB relays
date: 2026-06-01
status: resolved
tags: [incident, vpn, relay, france, msk, spb]
---
# 2026-06-01 — France via the RU relays (MSK→FR + SPB→FR)

**Type:** feature / infra · **Status:** live, verified · No app build (clients refetch `/config`).

User request: France should be reachable through **both** RU relays, not only NL
("что за полумеры"). Added two France legs:

| Leg | Tag | Where it shows | Mechanism |
|---|---|---|---|
| SPB→FR | `ru-spb-fr` | "Россия (обход белых списков)" group | nginx TCP stream forward |
| MSK→FR | `fr-via-msk` | under 🇫🇷 Франция ("Через MSK") | sing-box VLESS → WireGuard |

Both exit GRA `54.38.243.162` (France). Verified by real traffic:
`curl -x socks5h fr-via-msk → 54.38.243.162`, and `/config` emits both tags.

## SPB→FR (185.218.0.43, nginx stream)

- SPB box `chameleon-stream.conf`: added `upstream chameleon_fr_tcp { server 54.38.243.162:443; }`
  + `server { listen 2099; proxy_pass chameleon_fr_tcp; }`. Existing :443/:2096/:2098→NL
  untouched. Mirror committed in `infrastructure/spb-relay/chameleon-stream.conf`.
  Access: `sshpass -p "$SPRINTBOX_VPS_PASSWORD" ssh root@185.218.0.43`.
- DB: `vpn_servers` row `relay-fr` (host 185.218.0.43, port 2099, role=exit,
  category=whitelist_bypass, reality_public_key = **GRA's** key — the client
  Reality-handshakes GRA *through* the transparent forward).
- **GOTCHA (fixed):** the SPB box runs `ufw` (active). nginx listening on :2099
  is not enough — ufw allowed 443/2096/2098 but NOT 2099, so inbound to :2099
  timed out (`dial tcp 185.218.0.43:2099: i/o timeout`) and the app showed
  "SPB → FR" red. Fix: `ufw allow 2099/tcp`. **Any new SPB forward port needs a
  matching ufw allow.**

## MSK→FR (217.198.5.52 sing-box ⇄ 54.38.243.162 WireGuard)

Mirrors the existing msk→nl2 chain (sing-box userspace WireGuard).

- **GRA** (`54.38.243.162`): new WireGuard server `/etc/wireguard/wg-relay.conf`
  (interface 10.78.78.1/24, ListenPort 51820, NAT MASQUERADE out ens3, peer =
  MSK 10.78.78.2). `systemctl enable wg-quick@wg-relay`. ufw 51820/udp ← MSK only.
  Server pub `ZNUGFsgjYlQDrF8+m0d61B7HVfaX+qmP1u+KSYySHU4=`.
- **MSK** (`217.198.5.52`, `/etc/sing-box/config.json`, backup `config.json.bak-*`):
  added `vless-fr` inbound (copy of vless-nl, port 2099, same MSK Reality keys),
  `wg-fr` WireGuard endpoint (→ GRA:51820), route `{inbound: vless-fr, outbound: wg-fr}`.
  `sing-box check` OK before restart. iptables/ufw :2099 opened.
- DB: `relay_exit_peers` row `msk → gra1` (relay_listen_port 2099,
  relay_inbound_tag `vless-fr`, WG key material). This (a) makes the backend emit
  the `fr-via-msk` chain leaf and (b) makes RelayUserSyncer push the active user
  set to MSK's `vless-fr` inbound (relay.go:198) and to GRA's Reality inbound.

## Persistence / rollback

All changes survive reboot (wg-quick enabled, sing-box config persisted, nginx
config + repo mirror, DB rows). Rollback: set the DB rows `is_active=false`
(legs vanish from `/config` next fetch); SPB/MSK box configs revert from the
checked-in mirror / `.bak`. Existing NL legs (nl-via-msk, ru-spb-nl) were never
touched and still work.

## Follow-up

The MSK/GRA WireGuard key material + the `relay-fr`/`relay_exit_peers` rows are
infra state, not in git — captured here + in `docs/state/servers.yaml`.
