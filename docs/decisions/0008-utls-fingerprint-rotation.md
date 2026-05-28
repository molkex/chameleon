---
title: Per-user uTLS fingerprint rotation in generated client configs
date: 2026-05-28
status: active
tags: [vpn, singbox, utls, anti-dpi]
supersedes: none
refines: 0002
---

# 0008 — Per-user uTLS fingerprint rotation

## Context

[ADR 0002](0002-singbox-1.13-vless-reality.md) established VLESS Reality + uTLS as the primary protocol. The uTLS layer disguises the client's TLS ClientHello as a specific browser fingerprint (Chrome, Safari, etc.) so DPI middleboxes see what looks like ordinary HTTPS to `ads.adfox.ru`.

Until 2026-05-28 the generated client config hard-coded **every** user to `fingerprint: "chrome"` in `backend/internal/vpn/clientconfig.go`. That worked while we were small (a few hundred users) but is a long-term traffic-analysis liability:

- A correlated set of TLS handshakes — same SNI (`ads.adfox.ru`), same ClientHello fingerprint, hitting the same destination IP — is a fingerprintable cluster. RKN doesn't need to break Reality crypto to flag the cluster; aggregate traffic-analysis is sufficient.
- Real background HTTPS traffic in RU has browser-share diversity (Chrome dominant, Safari significant on iPhone/macOS, smaller Firefox + Edge tails). Our uniform "always Chrome" stands out *against* that diversity, not within it.

## Decision

Rotate the uTLS fingerprint **per-user, deterministically**, weighted to approximate global browser market share.

```
hash(user.Username) mod 100
  0..64  → chrome   (65%)
 65..84  → safari   (20%)
 85..94  → firefox  (10%)
 95..99  → edge     ( 5%)
```

Hash function: FNV-1a 32-bit. Not security-sensitive; we need uniformity + speed + zero allocs.

### Why deterministic per-user (not random per-call, not sing-box `random`)

Three alternatives considered:

| Strategy | Pro | Con |
|---|---|---|
| **A. Per-user deterministic** (chosen) | Reconnect-stable. A single user's sessions look like one browser → matches "I always use Chrome" behaviour. Distribution controllable. Debuggable (same user always gets same fingerprint in logs). | Compromised user always has same fingerprint forever. We accept this — the alternative is worse (per-session churn is itself a pattern). |
| B. Per-config-call random | Maximum entropy. | Each `/config` fetch flips fingerprint. Same iOS device looks like Chrome at 9am and Safari at 11am — that's *more* suspicious than stable fingerprint. |
| C. sing-box `random` literal | No backend logic. | sing-box's `random` rolls a fresh fingerprint per handshake (every TCP connection within a session looks like a different browser to a passive observer — no real device does that). Also pulls from sing-box's full set including `ios`/`android`/`360`/`qq` which are rarer in normal HTTPS traffic and would stand out. |

Strategy A makes our user base look like a population of normal HTTPS clients in aggregate, while each individual client looks consistent.

### Why these specific values

Only "real desktop browser" fingerprints are emitted: `chrome`, `safari`, `firefox`, `edge`. sing-box 1.13's full accepted set is `chrome / firefox / safari / ios / android / edge / 360 / qq / random`. We exclude:

- `ios` / `android` — rarer in passive HTTPS taps, and (counterintuitively) more identifiable as "VPN tunnel from mobile" if seen on traffic that's otherwise desktop-shaped.
- `360` / `qq` — China-specific browsers; very rare in RU LTE traffic.
- `random` — see C above.

## Consequences

- **No client change.** iOS re-fetches the config on cold start; the new fingerprint takes effect on next fetch. Old cached configs still work (chrome is still a valid fingerprint).
- **No server change.** Xray-core 25.12.8 sees the same VLESS Reality handshake either way — the uTLS layer is purely client-driven.
- **Adoption is gradual** as users' clients refetch their config. Backend log line per `/config` call: `"clientconfig generated" user_id=… utls_fingerprint=…` (added 2026-05-28) lets us correlate post-deploy handshake failures to fingerprint if any one of `firefox`/`safari`/`edge` turns out to behave differently against our actual Reality server config in the wild.
- **No on/off flag.** If we ever need to disable for debug, it's a one-line revert in `clientconfig_fingerprint.go`. A runtime kill-switch would be premature complexity.
- **SNI rotation is a separate concern.** ADR 0002 owns SNI policy (`ads.adfox.ru`); this ADR does not change it. SNI and fingerprint are independently rotatable.

## Status

Active.
