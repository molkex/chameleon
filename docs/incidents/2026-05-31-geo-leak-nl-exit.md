---
title: NL exit geo-leak — Gemini/Google geo-blocked over VPN
date: 2026-05-31
status: resolved
tags: [incident, vpn, geo, nl]
---
# 2026-05-31 — NL exit "looked Russian" (Gemini/Google geo-blocked over the VPN)

**Status:** RESOLVED 2026-05-31. Verified on device (whoer → USA, Gemini opens).

## Symptom

Connected to the NL VPN, the user was still flagged as being in Russia:

- `gemini.google.com` → "Gemini пока не поддерживается в вашей стране" (not available in your country).
- whoer.net showed **IP 147.45.252.234 → 🇷🇺 Россия** even though the node is physically in Amsterdam.

The whole point of the VPN (appear abroad) was defeated for geo-restricted services.

## Root cause — TWO independent leaks

### 1. DNS leak (VPN-GEO-DNS)

`backend/internal/vpn/clientconfig.go` resolved DNS through a **Russian** resolver:

- `route.default_domain_resolver` was `dns-direct` = **Yandex 77.88.8.8**.
- `dns-remote` (1.1.1.1) had no `detour`, so for proxied domains the resolution
  path still leaked RU.

Google/Gemini saw a Russian DNS resolver → inferred RU regardless of exit IP.

### 2. IP geolocation (NL-GEO) — the bigger one

The node's main IP **147.45.252.234** is on **Timeweb** (a Russian company). Geo-IP
databases used by the services that matter — **whoer, Google, MaxMind** — classify it
as **Russia** by the owner/AS, even though:

- it is physically in Amsterdam,
- RIPE registers the block ("TW-Cloud") to NL,
- and ip-api / ipinfo / db-ip / ip2location all say NL.

So the IP itself betrayed RU. **Not fixable by DNS/config** — it is the IP's reputation.

> **Key debugging lesson:** the public geo APIs (ip-api, ipinfo, ipwho, db-ip,
> ip2location) all said "NL" for the RU-flagged IP — they do NOT predict the
> whoer/Google verdict. **`geojs.io` (MaxMind-based) is the cheap proxy that DOES
> match:** it correctly showed 147.45.252.234 → Russia and the new IP → US. Use
> geojs/MaxMind to predict whether an IP will geo-unblock, not the generic APIs.

## Fix

### DNS (VPN-GEO-DNS) — `clientconfig.go`

- `dns-remote` (1.1.1.1) now has `"detour": "Proxy"` → non-RU domains resolve
  THROUGH the exit, so DNS geolocates to the exit country.
- `route.default_domain_resolver.server` changed `dns-direct` → `dns-remote`.
- `.ru` / banks / RU services stay on `dns-direct` (Yandex) via DNS rules.
- No app build — clients refetch `/config`. Validated with `sing-box check` on NL.

### IP (NL-GEO) — clean egress IP, source-bound

1. Bought an additional Timeweb IPv4 **72.56.79.25** via the Cloud API
   (`POST /api/v1/servers/6379091/ips`, hot-add, no reboot). A/B via geojs:
   147.45.252.234 → Russia, **72.56.79.25 → United States** (72.56.x is a legacy
   ARIN/US block reused by Timeweb).
2. Source-bound the **server** sing-box `direct` (user-egress) outbound to it:
   `inet4_bind_address: 72.56.79.25`. Clients still **connect** to the main IP
   147.45.252.234 (inbound); their traffic **exits** via 72.56.79.25.
3. Wired durably so it survives user registrations AND deploys:
   - `EngineConfig.EgressBindIP` (engine.go) → emitted on the `direct` outbound
     (singbox.go) on every config write.
   - `config.production.yaml` key `egress_bind_ip: ""` (default).
   - `deploy.sh` `nl2-1` branch: `sed` sets it to `72.56.79.25`.
4. IP persisted across reboot via systemd unit **`vpn-egress-ip.service`**
   (`ip addr add 72.56.79.25/32 dev eth0`). NOT in netplan (avoided the risk).

**Scope:** only the VPN container's egress changed. The co-located prod
`singbox-ss-ws` router and the backend's own egress were left untouched (the bind
is on the sing-box `direct` outbound, not a global SNAT).

## Verification (on device)

- whoer: **IP 72.56.79.25 / 🇺🇸 США** (was RU), DNS → Cloudflare NL.
- gemini.google.com → opens and responds (was country-blocked).

## Operations / gotchas

- **NEVER delete 147.45.252.234.** It is the MAIN IP — inbound (`:443` clients
  connect here), SSH, DNS A-records, MSK/SPB relay targets. Deleting it kills the
  whole node. Its RU geo no longer matters because user traffic *exits* via
  72.56.79.25, not the main IP.
- Two IPs by design: **147.45.252.234 = inbound (door in)**, **72.56.79.25 =
  egress (window out, what the world sees)**.
- The egress bind requires 72.56.79.25 to be present on `eth0` — if it ever
  disappears, sing-box's `direct` outbound can't bind. The systemd unit restores
  it on boot; if egress breaks, check `systemctl status vpn-egress-ip`.
- **To replicate on another node** (e.g. a clean exit elsewhere): buy/identify a
  clean-geo IP (verify with geojs/MaxMind, not generic APIs), add it on the NIC
  (+ persist), set `egress_bind_ip` for that node in `deploy.sh`, redeploy,
  restart sing-box.
- Timeweb pools differ: our main IP is **TW-Cloud** (RU geo); a friend's clean
  **TW-VDS** IP read Greece. The new 72.56.79.25 is TW-Cloud too but happens to
  sit in a US-geo ARIN block — geo is per-prefix, verify each IP individually.
- Caveat: a Timeweb IP is Russian-owned and could be reclassified later. A
  non-Russian host (Hetzner / the OVH France node) is the durable long-term play
  (see roadmap NL-RED-01 / GRA-PARITY).

## Files

- `backend/internal/vpn/clientconfig.go` — DNS detour + default resolver.
- `backend/internal/vpn/singbox.go` — `direct` outbound `inet4_bind_address`,
  `singboxOutbound.Inet4BindAddress`.
- `backend/internal/vpn/engine.go` — `EngineConfig.EgressBindIP`.
- `backend/internal/config/config.go` — `VPNConfig.EgressBindIP` (`egress_bind_ip`).
- `backend/cmd/chameleon/main.go` — wires `EgressBindIP`.
- `backend/config.production.yaml`, `backend/deploy.sh` — per-node value for NL.
- NL: `/etc/systemd/system/vpn-egress-ip.service`.

Roadmap: `VPN-GEO-DNS` (done), `NL-GEO` (RESOLVED).
