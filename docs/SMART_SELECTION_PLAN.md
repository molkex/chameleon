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
