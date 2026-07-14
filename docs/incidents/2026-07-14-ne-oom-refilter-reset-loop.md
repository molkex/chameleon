# 2026-07-14 — NetworkExtension OOM reset-loop (the RKN rule-set)

**Severity:** P0 — the tunnel silently reset its network every ~20 ms on real devices.
**Status:** fixed (backend deployed-pending; client needs a build).
**Symptoms reported by the owner:** "VPN отключается сам", "телеграм бесконечно грузит, медиа не всё грузит", "работает через раз".

## What was happening

`clientconfig.go` shipped two **remote** rule-sets. One of them, `refilter`
(the RKN blocklist, `teidesu/rkn-singbox`), is a **4.8 MB `.srs`** — 96× larger
than `geoip-ru.srs` (50 KB).

Remote rule-sets are re-fetched and parsed into RAM **on every tunnel start**:
`ConfigSanitizer.swift` deliberately strips `experimental.cache_file` (it
ballooned memory on first run), so `s.cacheFile` is nil and the cached-restore
path in `rule_set_remote.go` never runs.

iOS gives a packet-tunnel extension ~50 MiB. From a device log the owner
exported (103k lines, 2026-07-14 18:14–20:03):

```
[memory] sing-box started successfully (memory: 36MB/13MB avail)
[singbox] ERROR service/oom-killer[0]: memory pressure: critical, usage: 46 MiB, resetting network
```

sing-box started already **24–36 MiB deep** into the budget. Ordinary traffic
pushed it to 46 MiB, the fork's oom-killer fired `resetting network`, and then
looped: **62,756 occurrences** in that one log. `RealTrafficStallDetector`
signalled `reason=oomReset` 21 times.

A tunnel that resets its network every ~20 ms is why:
- the VPN "disconnected by itself" — it literally did;
- Telegram text arrived but **media never finished** — short flows squeezed
  through between resets, bulk transfers never did. (The earlier hypothesis —
  that Telegram's bare-IP MTProto flows fell through the route rules to
  `direct` — was **wrong**, or at most secondary. The OOM loop explains the
  symptom on its own.)

## The second half: the reset loop was NOT only about our own memory

The log line is `started memory pressure monitor` — and that names the bug.

`LibboxSetMemoryLimit(true)` makes libbox append a **default** oom-killer service
whenever the config declares none (fork `daemon/instance.go:90`). That default
carries **no options**, which selects *pressure-monitor* mode. In that mode
(`service/oomkiller/service.go`, the `adaptiveTimer == nil` branch) **every**
`DISPATCH_MEMORYPRESSURE_CRITICAL` event calls `router.ResetNetwork()`
unconditionally — it never looks at our own usage. The `usage: 46 MiB` in the
message is just a snapshot taken at the moment of the signal, not a threshold
that was crossed.

On iOS that signal is **device-wide**. So any memory hog anywhere on the phone
tore down every connection in *our* tunnel, over and over, for as long as the
system stayed under pressure. Our own bloat (refilter) made us both a
*contributor* to that pressure and a *victim* of it, but the blind reset loop
would have survived a pure diet.

The fork already supports the correct mode: declaring the service ourselves with
a `memory_limit` selects the **timer** mode (`service_timer.go`) — poll actual
usage, reset only when *we* are genuinely over. So the config now emits:

```json
"services": [{ "type": "oom-killer", "memory_limit": "45MB" }]
```

⚠️ **Unit trap:** sing-box's memory-unit table (`sing/common/byteformats`) maps
`"mb"` → MiByte, so `"45MB"` *is* 45 MiB — and `"45MiB"` is **rejected**
(`unsupported unit: MiB`), which makes sing-box refuse the entire config and the
tunnel fail to start. Caught only because the generated config was run through a
real `sing-box check` before shipping. This is exactly why the project rule
exists.

`ConfigSanitizer` injects the same service defensively, so a **stale cached
config** on a device gets the fix without waiting for a fresh fetch from the
backend.

## Why the list was there, and why it isn't needed

`refilter` existed to serve exactly one route rule:
`{rule_set: refilter → "Blocked Traffic"}`, which only mattered in the `smart`
mode, whose `Default Route` was **`direct`**. That is: "send nothing through the
VPN except what RKN blocks".

That shape was the root design error. It fails for two whole classes:
- traffic with **no domain to match** (Telegram's bare-IP MTProto — no SNI, no
  sniffer for it in the fork), and
- services blocked by the **far side**, not by RKN (Gemini, Flow, ChatGPT) —
  they are absent from an RKN list by definition.

Inverting the default ("everything through the VPN except Russia") makes the
list redundant: whatever it used to catch is proxied anyway. The RU allowlist
that remains (`ru_direct_domains.go` + `.ru` + `geoip-ru`, 50 KB) is **bounded**
and already maintained.

## Fix

1. **`refilter` rule-set and its route rule removed** (`clientconfig.go`).
2. **`Default Route` selector now has a single member, `Proxy`**, default `Proxy`.
   A VPN must fail *toward* the tunnel.
3. **`smart` mode retired** (`RoutingMode.swift`, `SettingsView.swift`). A
   persisted `"smart"` no longer decodes → `?? .default` migrates the user to
   `.fullVPN`, i.e. strictly more traffic through the tunnel, never less.
4. **oom-killer pinned to timer mode** — `services: [{type: "oom-killer",
   memory_limit: "45MB"}]`, emitted by the backend *and* injected defensively by
   `ConfigSanitizer`. See the section above; without it the network resets on
   device-wide pressure regardless of how lean we get.
5. **Mode-apply race fixed** (`ConfigSanitizer.swift`): the extension now bakes
   the user's persisted mode into the selector `default` fields *before* the
   engine starts. Previously **only the host app** applied the mode, post-connect,
   over the Clash socket, on a retry that gives up after 5 s — so any start
   without a live foreground app (on-demand, reboot, widget, app jetsammed) ran
   the baked-in mode regardless of the user's choice.

### The backward-compat trap (important)

The backend serves configs to **already-shipped clients**. Those still `PUT`
`"Default Route" = "direct"` when the user has `smart` persisted — and with
`refilter` gone, that would route **everything outside the tunnel**.

Guard: sing-box's `Selector.SelectOutbound()` returns `false` for a tag that is
not a member and keeps the current pick (`protocol/group/selector.go:122`). By
omitting `"direct"` from the `Default Route` members, those clients' PUT simply
fails and they stay on `Proxy`.

⚠️ **Do not add `"direct"` back to the `Default Route` selector while any
smart-capable client version is still in the wild.** Pinned by
`TestDefaultRouteSelectorProxiesOnly`.

## Verification

- `go build ./... && go test ./internal/vpn/` — green; 4 new tests
  (`TestRefilterRuleSetNotEmitted`, `TestEveryReferencedRuleSetIsDeclared`,
  `TestDefaultRouteSelectorProxiesOnly`, `TestRouteFinalIsDefaultRoute`).
- Generated config dumped and run through **real `sing-box check`** on the NL
  box (fork image `v1.13.6-userapi`) → **valid**. Note: the test fixture's fake
  UDP cert makes `check` panic in `NewSTDClient`; substituting the real
  `server.crt` is required to validate. The panic reproduces identically on
  `main`, so it is a fixture artefact, not a regression.
- iOS `BUILD SUCCEEDED`, macOS `BUILD SUCCEEDED`, `TEST BUILD SUCCEEDED`.

## Still open

- **A new client build must ship** — the ConfigSanitizer mode-apply fix and the
  retirement of `smart` from the UI only take effect there. The backend change
  alone is safe for old clients (see the guard above) and already removes the
  4.8 MB allocation, since the config is server-generated.
- `geoip-ru.srs` (50 KB) is still fetched from `raw.githubusercontent.com` with
  `download_detour: "direct"` on **every** start, and that fetch is **blocking
  and fatal** (`rule_set_remote.go:110`). GitHub raw is RKN-blocked in Russia —
  this is a live footgun for tunnel bring-up. Options: inline the set into the
  generated config, or mirror it on `api.madfrog.online`. Tracked in
  `roadmap.yaml#next.client_reliability`.
- The blunt `{network: udp, port: 443, action: reject}` rule kills all UDP/443,
  not just sniffed QUIC — suspected to break Telegram voice/video calls. Not
  investigated yet.

## Related

- The owner's other complaint the same day — **Google Flow geo-blocking** — is
  **unrelated to routing** and was not fixed by this change. Flow server-side
  redirects our Timeweb NL egress to `/unsupported-country`, while our OVH
  Poland and France exits load it fine. Root cause: our two Timeweb /24s are
  freshly re-registered ex-RU space (`72.56.79.0/24` created NL 2025-09-01) and
  Flow's geo pipeline (GCP-side) still reads them as RU/KZ, even though YouTube's
  own `GL` signal for the same IP says `NL`. Fix is exit selection, not config.
  See `docs/state/servers.yaml`.
