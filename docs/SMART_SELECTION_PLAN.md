# Smart-selection plan — adaptive outbound for Chameleon VPN

> Status: Phase 0 ✅ done (build 56). Phases 1-3 planned.
> Last updated: 2026-05-13

## Problem

Field log 2026-05-13: user on RU WiFi + LTE reports that Auto mode connects
but doesn't load whoer / loads Telegram media slowly. Logs show:

- `Auto urltest` picks `de-direct-de` on cold start (first available, 136 ms
  vs nl-direct 143 ms — tolerance=0).
- DE OVH (162.19.242.30) probe passes (`gstatic.com/generate_204` ~200 B
  succeeds) but real user TCP dies within ~3-30 seconds with `use of closed
  network connection` (DPI kill).
- `urltest` is blind to this — its only signal is the probe URL response. It
  re-elects only when *probe itself* fails, which under "DPI throttles bulk
  but passes small" can take 2.5+ minutes.
- Result: Telegram media (each photo/video = new TCP through dead outbound),
  Whoer (DNS-leak subdomains fail), every new connection stalls.

## Goal

Adaptive system that decides in the moment which outbound is best, with
zero user intervention. Fast (<1 s cold start, <10 s reaction to failure),
simple (single VPN on/off toggle, no manual mode picking), reliable (works
on any RU ISP / cellular / WiFi).

## Architecture (research-backed, 2026-05-13)

Two research rounds with WebSearch found:

1. **mihomo (Clash.Meta)** already has the v2 of what we'd build —
   LightGBM-based scoring + MAD anomaly detection + ASN-aware feature
   vector. We must cherry-pick, not reinvent.
2. **sing-box upstream refuses to add this** — issue #2061 ("Advanced
   automatic node selection") closed as "not planned / spam". Our fork is
   permanent.
3. **DPI can distinguish probe from user traffic** — TSPU uses 7 active
   probe types and packet-classifier. `generate_204` is a known signature.
   Probes must mimic user-flow size (4-32 KB random) to avoid being
   passed-through specifically.
4. **Pre-warming idle TLS = DPI fingerprint** — long-lived idle TLS sessions
   without traffic are anomalous. Replace with RFC 8305 Happy Eyeballs v2
   (CAD=250 ms) on cold start.
5. **EWMA α=0.3 too aggressive** — industry standard 0.05-0.25.
6. **Tailscale issue #16028 (May 2025)** confirms this is unsolved in
   industry generally; everyone freestyles. mihomo is the most mature.

## Phases

### Phase 0 — Universal NL-first hint (✅ done, build 56)

**What:** Backend's `/api/mobile/config` always sets `recommended_first =
"nl-direct-nl2"` (when that leaf is available). Passed into clientconfig
generator via `vpn.ClientConfigOpts{RecommendedFirst: hint}`. Generator
pins the hinted leaf to position 0 in both `Auto` urltest and the matching
inner country urltest (`_nl_leaves`). Tolerance bumped from 0 to 150 ms so
the hint stays sticky — urltest doesn't reselect on 5-15 ms latency drift.

**Why no geo gating:** Initially considered detecting RU/BY/CN/IR/... by
timezone/Accept-Language/geoip and hinting NL only for them. Decided
against it:

- For DPI users (RU/BY/CN/IR/etc.): NL is the only reliably working option
  on cold start. Geo-gating would help only those we successfully identify;
  missing edge cases (Belarus user with English iOS, RU user roaming
  abroad, Iran user on satellite) would still hit the dead-DE path.
- For non-DPI users (US/EU/JP/etc.): NL works fine. urltest converges to
  lowest-RTT within ~10 s if DE is genuinely faster, so the hint's impact
  is at worst neutral. Tolerance=150 prevents thrash on near-equal RTTs.

One rule for everyone, no special cases. Simpler to reason about, test,
and operate. Phase 1 (mihomo Smart group) will replace this static hint
with per-flow adaptive selection that works equally for all users.

**Code:**

- `backend/internal/vpn/engine.go` — added `ClientConfigOpts` struct +
  `GenerateClientConfigWithOpts` interface method.
- `backend/internal/vpn/clientconfig.go` — `pinRecommendedFirst` helper
  applied to `sortedLeaves` (Auto) and to matching country's
  `leavesByCountry[cc]` (inner country group). `tolerance: 0 → 150` for
  sticky hint behaviour. `configBuildMarker = "56.1-universal-nl-hint"`.
- `backend/internal/vpn/singbox.go` — `GenerateClientConfigWithOpts` impl.
- `backend/internal/api/mobile/geo_hint.go` — `resolveOutboundHint` (just
  checks if `preferredFirstLeaf` is in the available pool — no geo logic),
  `resolveOutboundHintForRequest`, `availableLeafTags`,
  `preferredFirstLeaf = "nl-direct-nl2"`.
- `backend/internal/api/mobile/config.go` — both `GetConfig` and
  `GetConfigLegacy` now call `GenerateClientConfigWithOpts`.

**Tests:** all TDD (test first, then code).

- `internal/vpn/clientconfig_test.go`:
  - `TestRecommendedFirstReordersAutoLeaves` — hint pins leaf to index 0.
  - `TestRecommendedFirstReordersInnerCountryGroup` — NL hint reorders
    `_nl_leaves`, doesn't pollute `_de_leaves`.
  - `TestRecommendedFirstIgnoredIfUnknown` — bad hint → default order, no
    config corruption.
  - `TestRecommendedFirstEmptyKeepsDefaultOrder` — back-compat.
  - `TestUrltestGroupsRecoverFast` — updated to assert tolerance=150.
- `internal/api/mobile/geo_hint_test.go`:
  - `TestResolveOutboundHint_ReturnsPreferredLeafWhenAvailable` — core
    invariant: hint always returns NL leaf when present.
  - `TestResolveOutboundHint_EmptyWhenPreferredAbsent` — config drift
    safeguard (no NL in pool → empty hint).
  - `TestResolveOutboundHint_EmptyOnEmptyInput` — defensive.
  - `TestAvailableLeafTags_MatchesClientconfigSynthesis` — leaf tag
    format must match clientconfig.go (test-side guard).
  - `TestAvailableLeafTags_SkipsServersWithoutCountry` — defensive.

9 new tests + 1 updated. `go test ./... && go vet ./...` clean.

### Phase 1.5 — Throughput-time threshold in TunnelStallProbe (✅ done, build 57)

Field log 2026-05-13 5:48 PM (LTE) showed build 56 with first-write
callback STILL missing the failure mode: 32 KB probe body arrived in
1.3-1.6 seconds (= 20-25 KB/s) — Speedtest timed out, Telegram media
stalled. No singbox errors, so first-write callback never fired. Throttle
is a separate class of failure from kill.

`Shared/TunnelProbeOutcome.swift` (new) — pure `(statusOK, bytes, elapsedMs)
→ .healthy | .throttled | .failed` classifier with default rules
(16 KB min body, 1000 ms max elapsed = ≥ 32 KB/s floor). 9 XCTest cases
cover field-log thresholds and edge cases (exactly-at-threshold,
partial-body, http-failure). `PacketTunnel/TunnelStallProbe.swift`
re-enables active fallback for degraded outcomes (build-44 had disabled
it on the assumption RealTrafficStallDetector — singbox-log parser —
would catch stalls; that worked for kill but is blind to throttle since
no errors appear in singbox logs under throttle).

### Phase 1.6 — App Review re-fix (✅ done, build 59 / 60)

App Review v1.0.26 reject 2026-05-13:
- **Guideline 2.1(a) Performance — App Completeness**: "Continue with
  Apple" did nothing on iPad Air 11" M3 / iPhone 17 Pro Max under
  iPadOS/iOS 26.5. Build 53 had moved away from SwiftUI
  `SignInWithAppleButton` to a UIKit `AppleAuthCoordinator` with explicit
  scene/window anchor lookup — our manual `connectedScenes` walk doesn't
  reliably find an anchor on iOS 26's multi-scene plumbing, so the
  system auth sheet never presented and no delegate callback fired.
- **Guideline 2.3.12 Performance — Accurate Metadata**: "What's New"
  text "Initial release" flagged as nondescript / placeholder.

Build 59 fix:
- Reverted to Apple's native SwiftUI `SignInWithAppleButton`. Apple's
  component handles iOS 26 scene wiring internally.
- Modal `.alert()` for SIWA errors (replaces the easy-to-miss red
  capsule). Reviewer can't miss a future error.
- `TunnelFileLogger.log` breadcrumbs at every SIWA step
  (tap → onRequest → onCompletion → credential / error).
- `.accessibilityIdentifier("onboarding.continue_with_apple")` for
  future UITests.
- `AppleAuthCoordinator.swift` kept in-tree but unused (safe to delete
  in a follow-up).
- L10n: new `onboarding.signin_failed.title` (RU "Ошибка входа" / EN
  "Sign-in error").

Build 60 followup — libbox memory regression fix (see Phase 1.9 below).

Resolution Center reply sent to App Review on 2026-05-13 19:47 explaining
both fixes. v1.0.26 (build 60) resubmitted, status "Waiting for Review".

### Phase 1.7 — Routing mode UX (✅ done, build 58)

Field log 2026-05-13 6:13 PM (LTE) showed user manually selecting
"Умный" then complaining Speedtest/Telegram don't work. Root cause:
"Умный" sounds like "smart = best behavior", but actually means "only
RKN-blocked sites through VPN, everything else direct". On cellular
where carriers throttle direct flows, this leaves Telegram, Speedtest,
YouTube etc. exposed to the throttle. Build 57 was working correctly;
the user just had the wrong mode picked.

Fix surface:
- `RoutingMode.default` changed `.fullVPN → .ruDirect` for new users.
- New `RoutingMode.recommended = .ruDirect` for UI badge.
- Smart mode label "Умный" → "Только блоки" (RU) / "Smart" → "Blocks only"
  (EN). Hint rewritten to WARN about cellular throttle leaving most apps
  exposed when picked.
- `Сплит-туннель` label gets `(рекомендуем)` suffix.
- SettingsView reorders segments: `[ruDirect, fullVPN, smart]` — pushing
  smart to the right of the segmented picker (least prominent).
- Tests: `testRecommendedModeIsRuDirect`, `testDefaultEqualsRecommendedForNow`,
  updated `testRawValueMappingFallsBackToDefaultForGarbage`.

### Phase 1.9 — Libbox memory regression (✅ done, build 60)

Field log 2026-05-13 19:43 (TestFlight build 58, user on cellular):

```
[19:42] sing-box restart (oom-killer auto)
[19:42] memory 28MB/21MB avail
[19:43] phys=48MB ... avail=1MB
[19:43-19:44] singbox oom-killer firing every ~20ms:
              "memory pressure: critical, usage: 47 MiB, resetting network"
```

User: "не грузит телегу вообще". Memory grew 28MB → 48MB in 60s of
Telegram traffic, internal singbox oom-killer reset the network ~500x/sec
to stay under iOS NE 50MB jetsam, killing every TG connection on each
reset.

Root cause: builds 56-58 shipped `Libbox.xcframework` built from sing-box
v1.13.6 (our fork HEAD). Production build 55 had v1.13.5. v1.13.6 has a
memory regression vs v1.13.5 under iOS NE's tight cap.

Build 60 fix:
- Reset fork branch to upstream `v1.13.5` tag.
- Cherry-picked first-write callback commit (`212010e`) onto v1.13.5 —
  applied cleanly, no conflicts. Phase 1 data-plane health preserved.
- Kept build tag exclusions (`with_tailscale`, `with_naive_outbound`,
  `with_dhcp` dropped — required for 50MB cap regardless of version).
- iOS-arm64 binary 44MB, byte-equivalent to production build 55 size.
  Slice Info.plist patched with `CFBundleShortVersionString=1.13.5`,
  `io.nekohasekai.libbox`.

Test guard (build 60+, `LibboxVersionGuardTests`):
- `testLibboxIsPinnedToExpectedVersion` — fails if `LibboxVersion()`
  doesn't start with `1.13.5`. Would have caught the 56-58 regression
  pre-TestFlight. Bump `expectedSingboxBase` only after on-device memory
  bench (RSS < ~35MB under TG/Safari load).
- `testLibboxVersionIsNotEmpty` — defensive, catches a broken gomobile
  bind wiring that would return empty version.

166/166 iOS XCTests green (was 164, +2 guards).

### Phase 1.A — Suppress QUIC outbounds (✅ done, marker 60.2-no-quic-outbounds)

Field log 2026-05-13 21:55 (TestFlight build 60, user on RU LTE) showed the
v1.13.5 revert did NOT fix the OOM-killer storm:

```
[21:55:27] singbox oom-killer firing 100x/sec at 43 MiB usage
[21:55:28] resetting network → all TG connections die
[21:55:54] extension auto-restart by iOS jetsam
```

Re-investigation: between v1.13.5 (build 55, last known-good) and v1.13.6
(builds 56-58, OOM regression) the only upstream change is `sagernet/sing`
v0.8.3→v0.8.4, which contains a single line diff in `copy_direct_posix.go`
(`Iovec(Cap())` → `Iovec(FreeLen())`). For freshly-created buffers
`Cap()==FreeLen()`, so this change is provably no-op in our hot path.
**The libbox revert (Phase 1.9) was the wrong call** — wasted a TestFlight
cycle. Root cause sits elsewhere.

Config audit (build 60 init log) reveals **44 outbounds** initialised at
tunnel start: 9 selectors, 5 urltest groups, 10 leaves (`de-direct-de`,
`de-h2-de`, `de-tuic-de`, `nl-direct-nl2`, `nl-h2-nl2`, `nl-tuic-nl2`,
`de-via-msk`, `nl-via-msk`, `ru-spb-de`, `ru-spb-nl`). The four QUIC leaves
(`*-h2-*`, `*-tuic-*`) **reliably time out on RU LTE** (`outbound nl-tuic-nl2
unavailable: timeout: no recent network activity`) yet still cost ~2-3 MiB
each on Go heap — BBR congestion state + uTLS handshake state. ~10 MiB of
permanently dead allocations against the 50 MB iOS NE jetsam cap.

Fix: env flag `CHAMELEON_DISABLE_QUIC_OUTBOUNDS=true` in
`backend/docker-compose.yml`, read in `clientconfig.go` per-call so tests
can flip via `t.Setenv`. Suppresses h2/tuic emission in mobile client
config. Default off (zero behaviour change on non-cellular nodes).

Verified by field log after re-deploy:
- 0 oom-killer events (was 103218 in prior 4-minute run)
- 6 leaves init instead of 10, no `outbound/hysteria2` or `outbound/tuic`
  init lines
- TG works for first ~90 s on LTE before DPI throttle kicks in
  (separate problem, addressed in Phase 1.B)

### Phase 1.B — DPI-aware config filter (✅ done, marker 60.3-dpi-aware-config)

After Phase 1.A removed OOM, user reported "то грузит, то не грузит" on LTE
— some pages load, some hang. Field log diagnosis:

```
[22:16:44] outbound de-direct-de unavailable: read tcp ...→162.19.242.30:443:
            use of closed network connection
[22:17:08] outbound de-direct-de unavailable: context deadline exceeded
[22:17:23] outbound de-direct-de unavailable: context deadline exceeded
[22:17:38] outbound de-direct-de unavailable: context deadline exceeded
```

The Auto urltest cycle probes ALL leaves every 15 s including the dead
`de-direct-de`. Every probe waits 5 seconds for the OVH 162.19.242.30 TCP
timeout. Net effect: one third of every 15-second urltest cycle is
spent stuck on a dead probe. User perceives this as "VPN hangs every 15 s".

Root cause: DE OVH Frankfurt (162.19.242.30) is ASN-blocked from RU/BY
mobile carriers (МТС/МегаФон/Билайн/Yota and A1/life: in Belarus). NL
Timeweb (147.45.252.234) is reachable but throttled — usable as fallback.
Phase 0 hint `nl-direct-nl2` only re-orders the list; it does not remove
the dead leaf, so urltest keeps probing it.

Fix:
- Wire `ClientConfigOpts.ClientCountryCode` end-to-end (engine.go → config.go).
- `mobile/config.go::resolveClientCountry(c)` calls `geoip.Lookup(c.RealIP())`
  capped at 1 s — slow upstream (free ip-api.com, 45 req/min) can never
  block /config; safe-empty on miss.
- `clientconfig.go::clientNeedsDPIBypass(opts)` checks the country against
  `dpiBlockedDirectCountries{RU, BY}`.
- In the standard-exits loop: if `suppressDEDirect && cc == "DE"`, skip the
  whole iteration (no leaf, no autoLegs append). H2/TUIC blocks below are
  still gated by Phase 1.A flag — both stripped in concert for RU clients.
- NL direct stays (throttled but reachable). The `de-via-msk` chain stays
  (intended DE exit path from inside the DPI envelope).

Safe-fallback contract: empty `ClientCountryCode` (geoip down, IP private,
or timeout) means "ship full config". No outbound is stripped without
positive geographic identification.

5 new tests cover RU→no-de-direct, BY→no-de-direct, US→full, empty→full,
and case-insensitive normalisation. Full backend suite (vpn/api/auth/...)
green.

CF→nginx→Echo pipeline already gives the real client IP via
`CF-Connecting-IP` header (see `backend/nginx.conf:39`, commit b7f09c2 for
the XFF-spoof fix that made this trustworthy).

Pending field verification after user reconnects on LTE (force-quit
required to trigger `silentConfigUpdate`).

### Phase 1.C — Adaptive probe cadence (✅ code merged, awaiting build 61)

Following Phase 1.B, the dead-probe waste is gone, but `nl-via-msk`
(through MSK relay 217.198.5.52:2097) still gets DPI-throttled around 90
seconds in (probe 502 ms → 391 ms → 439 ms → **5601 ms THROTTLED**).
TunnelStallProbe DOES catch this (`probe THROTTLED(5601ms)` → `probe
degraded #1`) but needs `stallThreshold=2` consecutive degraded probes
before firing `invokeFallback()` — at 15 s interval that's 30 s before
re-probe kicks in.

Implementation (commit 6005fa5):
- `TunnelStallProbe.applyCellularProfile()` → `stallThreshold=1`,
  `probeInterval=5s`. Single degraded probe + 5 s cadence ⇒ fallback
  within ~10 s of throttle onset.
- `TunnelStallProbe.applyWiFiProfile()` → restore defaults 2/15.
- `config` is now `var` (not `let`) so the loop reads
  `config.probeInterval` per-iteration — mid-flight profile swap takes
  effect on the very next tick, no probe restart.
- `ExtensionPlatformInterface` gains `weak var stallProbe` and dispatches
  the profile swap inside the existing `handlePathUpdate` based on
  `NWPath.isExpensive` (Apple's canonical cellular flag — covers carriers
  and tethered hotspots).
- `ExtensionProvider.startStallProbe()` injects the weak ref on tunnel
  start; `stopStallProbe()` clears it on tunnel stop.

Build verification: PacketTunnel target compiles clean on iOS Simulator
SDK. Unit tests not currently runnable on sim (App Group entitlement
unavailable without real provisioning — pre-existing gating, unrelated
to this change). Authoritative verification path: install via TestFlight,
flip Wi-Fi/cellular, check log lines:

```
TunnelStallProbe: cellular profile applied (threshold=1, interval=5s)
TunnelStallProbe: wifi profile applied (threshold=2, interval=15s)
```

Pending: bump `clients/apple/project.yml::CURRENT_PROJECT_VERSION` from
60 to 61 and `xcodebuild -exportArchive` upload. Deferred until user
confirms Phase 1.B (60.3-dpi-aware-config) made a visible difference —
no point shipping Phase 1.C if 1.B alone closed the UX gap.

### Phase 1.D — Penalty-score recently-throttled outbound (planned)

The current `nudgeUrltestGroups()` fallback calls `client.urlTest(group)`
which re-probes ALL members equally. If the throttled outbound passes a
fresh small probe (DPI may have eased after the wait), it gets re-elected
and the user is back in the throttled state within seconds.

Plan (deferred — needs Clash API extension):
- After `invokeFallback()`, mark the currently-active outbound with a
  60-second penalty score via Clash API.
- urltest member-selection biased: penalised outbound only chosen if no
  other healthy member exists.
- Penalty decays linearly to zero over 60 s.

Requires Clash API addition (mihomo has this — `proxies/:name/delay`
exposes the score, but penalty injection is missing). Either upstream PR
or fork-only Clash extension. Not blocking — Phase 1.C alone may close the
loop adequately.

### Phase 1 — Cherry-pick mihomo Smart (planned, 2-3 days)

**What:** In our fork `singbox-with-userapi`:

- Cherry-pick `adapter/outboundgroup/smart.go` +
  `common/callback/callback.go` + `provider/healthcheck.go` from mihomo.
- Adapter shim `mihomo.Proxy ↔ sing-box.Outbound` (~50 lines).
- New outbound type `smart` next to upstream `urltest` (no modification of
  upstream code — minimum diff for future rebases).
- `backend/internal/vpn/clientconfig.go` switches `type: "urltest" →
  "smart"` for Auto / `_de_leaves` / `_nl_leaves`.

**Parameters (research-backed, not arbitrary):**

- EWMA α = 0.1 (not 0.3 — industry standard 0.05-0.25).
- Sliding window 30 s, min_samples = 5.
- MAD k = 2.5 for anomaly detection.
- Error-rate threshold = baseline_EWMA × 3.5 (not fixed count).
- Cooldown 60-120 s after switch.
- `failedTimes` threshold 3 in 30 s for hard-override.

**Tests:**

- `testing/synctest` (Go 1.24) for deterministic time control of EWMA
  windows, cooldowns, MAD thresholds.
- `Shopify/toxiproxy` integration tests: mock VLESS server, toxics
  `bandwidth` / `slow_close` / `reset_peer`. Scenarios:
  - leaf throttled to 50 KBps for 45 s → smart switches in <10 s.
  - leaf killed on first write → smart switches in <1 s.
  - two equivalent leaves → no flapping over 10 min.
- `uber-go/goleak` after each test (smart loops = goroutine festival).
- `pgregory/rapid` property tests: "single healthy leaf is always active",
  "after cooldown switch is possible", "monotonic score vs error_rate".
- `pingcap/failpoint` for injecting `Conn.Write` errors (arm64 macOS
  compatible, unlike gomonkey).

### Phase 2 — Anti-correlation + State machine (1.5 days)

**What:** In smart-group:

- State machine `HEALTHY → DEGRADED → UNHEALTHY → COOLDOWN → HEALTHY`.
- Transitions by MAD-bucket, not percentage thresholds (adaptive to noise).
- Probe-mimic: payload 4-32 KB random, URL = our own
  `https://api.madfrog.online/cdn-cgi/healthcheck` (new endpoint, returns
  randomized payload to defeat TSPU signature matching).
- Score-update only from user-flows, not probes (probe only for liveness in
  COOLDOWN state).

### Phase 3 — Happy Eyeballs v2 + LTE hard rules (1 day)

**What:**

- iOS: `NWPathMonitor.cellular` → libbox flag via `LibboxCommand`.
- Cold-start: race-dial 2 leaves with CAD = 250 ms (RFC 8305).
- LTE detected → smart-group receives `disabled_outbounds: [de-h2,
  de-tuic, nl-h2, nl-tuic]` (hard rule, not score-bias — UDP transports
  consistently broken on cellular NAT-rebinding).
- WiFi → all leaves enabled.

## Anti-patterns (verified by research, not to repeat)

- ❌ Single-error switch → flapping. Always require hysteresis (3+ errors
  in window with MAD-relative threshold).
- ❌ `generate_204` as probe under DPI — TSPU has signature for it.
- ❌ Pre-warming idle TLS → fingerprint for DPI.
- ❌ EWMA α > 0.25 → false alarms on transient blips.
- ❌ `tolerance: 0` urltest → constant outbound thrash on near-equal RTT.
- ❌ Building "smart" as a new outbound type that requires upstream merge —
  issue #2061 closed not planned. Forever-fork is the only path.
- ❌ Reinventing scoring formulas — mihomo already iterated to ML model.
- ❌ Continuous scoring without state machine wrap — untestable and prone
  to oscillation.

## References

- [mihomo wiki](https://wiki.metacubex.one/en/config/proxy-groups/) —
  Smart group, LightGBM, ASN feature.
- [mihomo callback.go](https://github.com/MetaCubeX/mihomo/blob/Alpha/common/callback/callback.go) —
  first-write callback.
- [sing-box issue #2061](https://github.com/SagerNet/sing-box/issues/2061) —
  closed not planned.
- [Tailscale #16028](https://github.com/tailscale/tailscale/issues/16028) —
  May 2025, same problem unsolved.
- [RFC 8305 Happy Eyeballs v2](https://datatracker.ietf.org/doc/html/rfc8305).
- [How China Detects and Blocks Shadowsocks (IMC 2020)](https://dl.acm.org/doi/10.1145/3419394.3423644) —
  probe-vs-traffic anti-correlation.
- [Go testing/synctest blog](https://go.dev/blog/synctest).
- [Shopify/toxiproxy](https://github.com/Shopify/toxiproxy).
