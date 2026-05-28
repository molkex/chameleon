---
title: sing-box 1.13 with VLESS Reality TCP as primary protocol
date: 2026-04-20
status: active
tags: [vpn, singbox, reality]
---

# 0002 — sing-box 1.13 + VLESS Reality TCP

## Context

iOS NetworkExtension memory cap is tight (~50 MB jetsam). Older clients we tried:

- **OpenVPN-iOS** — bloated, ~80 MB resident, frequent jetsam kills under load.
- **WireGuard** — fast but DPI-trivial (UDP/51820 pattern), blocked by RU GFW.
- **Xray-core** — server-side compatible but client mobile binding limited.
- **sing-box** — clean Go core, libbox iOS bindings, modular outbounds, 50 MB headroom with GOMEMLIMIT.

For protocol: **VLESS Reality** beats everything else for RU evasion in 2025-2026:

- TLS-tunnels-inside-TLS to a real domain (`ads.adfox.ru` in our case) — looks like ordinary HTTPS even under SNI inspection.
- No identifiable handshake (vs WireGuard) — DPI sees normal TLS to ads.adfox.ru.
- Hysteria2 (UDP) and TUIC v5 as backup outbounds, served by the same node.

## Decision

- **Server:** sing-box 1.13.5 (custom fork — see [0007-singbox-fork.md](0007-singbox-fork.md) when written) inbounds: VLESS Reality :443/tcp, Hysteria2 :443/udp (where available), TUIC v5 :8443/udp.
- **Client:** libbox 1.13 via NetworkExtension. Built from `make lib_apple` (sagernet/gomobile fork). Slices: ios-arm64, ios-arm64_x86_64-simulator, macos-arm64_x86_64.
- **SNI:** **NEVER** use google.com / cloudflare.com (RKN-blocked patterns). `ads.adfox.ru` is verified clean for RU. New SNI must be checked against RKN block list before adoption.
- **Migration discipline:** when sing-box version bumps, read `https://sing-box.sagernet.org/migration/` BEFORE generating new configs. Validate with `sing-box check -c config.json` on the server before any client rollout.

## Consequences

- Tunnel survives RU DPI for the vast majority of users (live since 2026-04 with no widespread blocking reports).
- Memory headroom enough that we can run cascade fallback logic in the extension without OOM (see `build-31..build-77` work in [`../../clients/apple/MadFrogVPN/Models/AppState.swift`](../../clients/apple/MadFrogVPN/Models/AppState.swift)).
- Xray-core kept on the server side as the inbound listener; sing-box client speaks VLESS to it. Note: Xray v26 is **incompatible** with sing-box 1.13 — pin Xray to **25.12.8**.
- sing-box `mux` (h2mux) is **incompatible** with Xray server — don't enable on the client.

## Status

Active. Track migration guide on every sing-box patch release.
