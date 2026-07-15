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

---

## 2026-07-15 — SEQUEL: the timer-mode fix collided with the Go soft cap (my regression)

Shipping `memory_limit: "45MB"` (1.0.34) made it WORSE — the user reported
disconnects got *faster*. Root cause, verified in the fork source (Fable review,
cross-checked):

- The oom-killer timer compares **`memory.Total()` = task_info `phys_footprint`**
  — the WHOLE process (Go heap + all native CFNetwork / TLS / tun memory), the
  same counter jetsam enforces — not the Go heap
  (`sing/common/memory/memory_darwin.go`).
- libbox *separately* soft-caps the Go heap at 45 MiB (`SetMemoryLimit`,
  `experimental/libbox/memory.go`). Setting the oom-killer trip point ALSO at 45
  MiB put it **below** the normal operating footprint: native memory alone is
  ~5–12 MiB, so the effective Go-side trip was ~33–40 MiB. Any bulk transfer
  (Telegram media) crossed 45 and tripped it.
- The trip is `ResetNetwork()` — closes **every** connection + flushes the DNS
  cache (`route/router.go`). Telegram retries → memory climbs → trips again. A
  self-sustaining, load-following reset loop.
- It also can't self-recover: the timer arms on the first critical pressure event
  and never disarms — the dispatch source subscribes to `WARN|CRITICAL` only, so
  the `normal`→`stop()` branch is unreachable dead code
  (`service/oomkiller/service.go`).

**Fix (backend, no build): `memory_limit "48MB", max_interval "60s"`.** The
correct ordering is Go soft cap (45) < backstop (48) < jetsam (50, the NE hard
limit since iOS 15). 48 MiB never trips on a legitimate ~45–47 MiB transfer; it
only catches a real runaway just before the kernel would kill us. `max_interval`
caps a pathological plateau at 1 reset/min instead of the default 6. Deployed to
WAW, verified in the running binary, validated with `sing-box check`.

**Unit trap remains:** the trip metric is phys_footprint, not the Go heap — any
future memory_limit MUST stay above the Go soft cap or this recurs. Pinned by
`TestOOMKillerServiceHasExplicitMemoryLimit` (now also rejects a regression to
45MB).

### Still needs a client build (1.0.35) — deeper fixes

- **Rebase `service/oomkiller` onto current upstream sing-box** (post-2026-06-28).
  Our fork ships a Feb-2026 prototype; upstream since fixed the never-disarm bug
  and added arm/resume hysteresis, interval backoff, and rate-based early trigger.
- **Lower the Go soft limit below the trip point** (~37 MiB) and delete the inert
  `setenv GOMEMLIMIT/GOGC` block in `ExtensionProvider.swift` (it runs after the
  Go runtime is already up and is overridden by `LibboxSetMemoryLimit` — the
  "GOMEMLIMIT=38MiB" log line describes a config that is NOT in effect).
- **Plug the `TunnelStallProbe` URLSession leak** (`TunnelStallProbe.swift`): a
  new ephemeral `URLSession` per probe every 15 s, never invalidated — unbounded
  NATIVE-memory growth (invisible to Go GC, fully counted in phys_footprint), the
  prime suspect for "fine at first, disconnects later." One shared session, or
  `finishTasksAndInvalidate()`.
- Bundle `geoip-ru.srs` locally / stop stripping `cache_file` — removes the
  per-start download+parse spike and the censored-network dependency.

### Industry note (why this pattern is fragile)

The "oom-killer that resets the network on pressure" is an upstream sing-box
crutch that only landed April 2026 and is still undocumented. The mature-client
playbook (Tailscale, WireGuard-iOS, and Apple DTS guidance, thread 44942) is
**footprint discipline + flow control, with jetsam as the honest backstop** —
NOT self-inflicted network resets. Apple gives NE providers no memory-warning
callback; the sanctioned strategy is self-imposed buffer bounds. Long-term we
should aim to keep the footprint low enough that the killer never fires, and
treat it as a last-resort backstop we never actually see.

---

## 2026-07-15 (evening) — the timer-mode oom-killer itself is the problem; disable it (512MB)

The 48MB backstop wasn't enough. The user reported **instant** disconnects on 1.0.34.
Backend `app_events` telemetry gave the definitive diagnosis (no device log needed —
with no VPN the RU user couldn't reach support):

- Every `vpn.connect.start` → `vpn.connect.success`: the tunnel **reaches connected**.
  Not a parse failure, not a broken build.
- Connects come in bursts (22:18:34 → 22:19:19 → 22:21:07): connect, drop seconds
  later, reconnect. A **post-connect reset loop**.
- `routing: "full-vpn"` — all traffic through the tunnel, so the NE footprint runs hot
  and the timer-mode oom-killer (measuring whole-process phys_footprint) trips during
  use and `ResetNetwork()`s the live tunnel. full-vpn amplifies it → "instantly".

**Decision: stop trying to place a backstop below jetsam on this client.** The fork's
Feb-2026 oomkiller never disarms, and any trip point at/below the operating footprint
loops. The *only* reason to emit the service at all is to select timer mode and thereby
**disable** libbox's default pressure-monitor mode (the original 62k-reset bug). So set
`memory_limit` ABOVE the ~50 MiB jetsam ceiling (`512MB`): timer mode selected,
pressure-mode disabled, timer never fires. If the NE genuinely runs away, iOS
jetsams+restarts it — the honest backstop the mature-client playbook uses (Tailscale,
WireGuard-iOS, Apple DTS thread 44942), instead of self-inflicted network resets.

`max_interval` was also removed here (an earlier suspicion that it broke the client
parse was **refuted** — `strings` on Libbox.xcframework shows `max_interval`,
`memory_limit`, etc. are all present in the shipped v1.13.5 build; the field parsed
fine. It was dropped only because at 512MB the timer never fires, so it's moot).

Deployed to WAW, validated with `sing-box check`, verified in the running binary.
Telemetry proves the app fetches config + logs events over the network, so the 512MB
config reaches the device on the next connect.

**The real fix stays a 1.0.35 client build:** rebase `service/oomkiller` onto current
upstream (disarm + hysteresis), drop the Go soft cap to ~37 MiB, plug the
TunnelStallProbe URLSession leak. Only then is a real backstop below jetsam safe. The
whole episode is the cautionary tale for invariant I-1 in ADR 0014 (never tune NE
memory blind — measure on-device before/after).

---

## 2026-07-15 (midday) — the real root cause: iOS jetsam, not the oom-killer

A fresh 231k-line device log (1.0.34, running the 512MB oom config) settled it. With
`memory_limit: 512MB` the oom-killer timer no longer fires — the log shows
`memory pressure: critical` as WARN only, **no `resetting network`**. So the oom-killer
saga was, from the start, treating a symptom. The real failure:

- `sing-box started successfully (memory: 41MB/8MB avail)` — the NE starts **41 MiB**
  deep into its ~50 MiB budget, 8 MiB headroom.
- At cold start, urltest immediately probes **every leg** (nl-direct-nl2, nl-via-msk,
  pl-via-msk) — concurrent Reality-TLS handshakes — plus the geoip-ru remote
  fetch+parse. phys_footprint crosses the ~50 MiB hard ceiling.
- The `[singbox]` log goes **silent mid-line at 12:06:26**, ~4 s after connect; the app
  sees `status=1` at 12:06:52. No graceful stop, no oom log — the signature of an **iOS
  jetsam SIGKILL** (a process can't log its own kill). 22 tunnel starts in one log = the
  device reconnecting into the same wall over and over.

So: my earlier oom-killer tuning (45→48→512 MB) correctly removed the self-inflicted
resets but **exposed** the underlying bloat — the NE is genuinely too fat and iOS kills
it. No backend oom setting can fix that.

### Fixes (2026-07-15)

**Emergency, backend, no build (deployed):** `emergencyNoUrltest` in clientconfig.go —
Proxy becomes a PLAIN selector over the raw legs, default nl-direct-nl2 (the leg urltest
itself picked, 42 ms in the log). A plain selector dials **only the default** at cold
start → one handshake → the NE stays under the ceiling. Auto + country urltest groups
are not emitted. Cost: no auto RTT-selection / cross-leg failover (owner explicitly
accepted this stopgap); both countries stay manually selectable. One-line revert.

**Real fix, client build 1.0.34 (135):** NE memory diet —
1. **geoip-ru.srs bundled** into the extension; ConfigSanitizer rewrites the remote
   rule_set to `{type:"local", path}`. Kills the per-start download+parse AND the
   RKN-blocked-GitHub dependency. Local form validated with `sing-box check`.
2. **TunnelStallProbe URLSession leak deleted** — it created a new ephemeral URLSession
   every 15 s without invalidation (unbounded native-memory growth). `nudgeNow` kept.
3. **Inert setenv GOMEMLIMIT block deleted** (ran too late, overridden by
   LibboxSetMemoryLimit — never took effect).

Once 135 is verified on-device to hold under the ceiling, flip `emergencyNoUrltest` back
to false to restore auto-selection. The deeper baseline cut (lower the Go soft memory
cap, needs a libbox rebuild) stays a follow-up — the 41 MiB baseline is mostly libbox +
Go runtime, and only a rebuild moves it materially.

### Lesson (reinforces ADR 0014, invariant I-1)

Do not tune NE memory blind. Every one of the 45→48→512 MB steps was a guess without an
on-device before/after number, and each shifted the symptom instead of fixing it. The
device log — not reasoning — is what finally identified jetsam. The exportable
`TunnelFileLogger` (with the `memory: NN MB/NN avail` line) is the measurement of record;
every NE-memory change must cite a before/after from it.

---

## 2026-07-15 (afternoon) — on-device investigation: it's a THREE-vector iOS resource kill, and logging is the amplifier

Built an autonomous on-device test rig (see memory `reference_autonomous_iphone_control`):
WebDriverAgent rebuilt under the org team (99W3C374T2) + run via Xcode's CoreDevice
tunnel (NO sudo) → I drive the iPhone (turn VPN on/off) over USB; memory read live via
`idevicesyslog` watchdog lines; crash reports pulled via `pymobiledevice3 crash` (needs
the user's one-time `sudo pymobiledevice3 remote tunneld`).

**The user reported: whoer.net (an IP-leak test = connection storm) disconnects the VPN.**
I reproduced it and the extension died within ~4s — with 0 oom `resetting network` and
0 `memory threshold`, i.e. NOT our oom-killer. Pulling the device crash reports gave the
real cause — the NE is killed by iOS **resource limits, three vectors, all confirmed**:

- **`PacketTunnel.cpu_resource` (bug_type 202):** "144 seconds cpu time over 149 seconds
  (**97% cpu average**), exceeding limit of 80% cpu over 180 seconds." A near-idle VPN
  tunnel burning 97% CPU = the logging (per-packet INFO at log.level=info + the oom-killer
  logging a WARN on every DISPATCH_MEMORYPRESSURE_CRITICAL, ~32/s near the ceiling).
- **`PacketTunnel.diskwrites_resource` (2026-07-12, -13):** exceeded the disk-write limit —
  the TunnelFileLogger FILE hit 28 MB / 227k lines.
- **`JetsamEvent`:** memory jetsam near the ~50 MiB ceiling.

**Live measurement (build 135, driven by me):** phys_footprint **26 MiB idle → 43–47 MiB
under load**, PID stable when idle (not killed), 0 self-resets. So build 135 + the emergency
config HOLDS in normal use, but sits ~3 MiB under the ceiling — a whoer.net connection
storm spikes memory + CPU + disk (via logging) past the limits in seconds → iOS kills it.

**The owner's "maybe it's the log" hunch was the ROOT, confirmed three independent ways.**

### Status of today's fixes vs this

- log.level "info"→"error" (backend, deployed): cut per-packet INFO (device shows ~28 vs
  thousands). BUT the memory-pressure WARN spam PERSISTS on-device (~1111 lines/35s) even
  after app kill+relaunch — either the device is still on a stale cached config, OR the
  fork's oom-killer logger is NOT gated by the config log.level (standalone logger). UNRESOLVED
  — load-bearing for whether log=error can silence the pressure spam. Needs a fork read.
- emergency no-urltest + memory diet 135 + geoip-bundle: all reduce the baseline/CPU but
  don't create real headroom — the baseline is still ~47 under load.

### The real fix (next session): rebuild libbox

Consensus all along: the only thing that moves the baseline is a **Libbox.xcframework rebuild**:
1. Lower the Go soft memory cap in `experimental/libbox/memory.go` (currently
   `SetMemoryLimit(45 MiB)` + `SetGCPercent(10)` — 45 leaves ~3 MiB headroom; target ~32–37
   MiB, mind the GC death-spiral).
2. Silence the oom-killer's per-event pressure logging (fork `service/oomkiller/service.go`
   ~line 165 `s.logger.Warn`) — drop to Debug or gate it, so it stops burning CPU/disk when
   the process sits near the ceiling. (Or find a cleaner way to disable libbox's default
   pressure-monitor ResetNetwork without emitting a spammy service at all.)
3. Rebuild via `make lib_apple` (mind the Info.plist patching for App Store validation, 3
   slices, GitHub Release re-upload — see reference_libbox_build).
4. VERIFY on-device before/after with the new WDA+idevicesyslog rig (phys_footprint under a
   whoer.net storm must stay well under 50).

Fable + Sonnet were consulted 2026-07-15 for the ranked rebuild plan — fold their answers in
here next session before starting the rebuild.
