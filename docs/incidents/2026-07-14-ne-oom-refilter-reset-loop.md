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

---

## 2026-07-15 (evening) — Fable + Sonnet consulted; the log=error fix is a DEVICE-SIDE NO-OP, and the real plan

### The load-bearing correction (Fable, verified in fork source)

**`log.level: "error"` cannot silence ANY on-device logging** — it is not a stale config,
it is a structural bypass in sing-box's log pipeline:
- `sing-box-fork/log/observable.go:114` — the level early-out only fires when there is NO
  platform writer.
- `log/observable.go:140-142` — when a platform writer exists (always, on iOS:
  `daemon/instance.go:109`), EVERY line at EVERY level is formatted and delivered
  unconditionally; `l.level` gates only the internal writer.
- `ExtensionProvider.swift:454` sets `setupOptions.debug = true` → every line crosses the
  gomobile bridge to `ExtensionPlatformInterface.swift:393` `writeDebugMessage` → os_log
  mirror + TWO file sinks + a `stat()` per line.
So today's backend `Log.Level "error"` change (and ConfigSanitizer's long-standing Release
`level="error"`) are **device no-ops**. The 97%-CPU and disk-write kills were reachable
*despite* error level all along. **Only `emergencyNoUrltest` actually cut CPU today.**

### Consensus plan (Fable + Sonnet agree)

**Client build — NO libbox rebuild needed (kills 2 of 3 kill-vectors):**
- **Raise the file-sink filter to ≥ WARN** in `ExtensionPlatformInterface.swift` (~lines
  372, 389; `writeDebugMessage` skips both file sinks for non-WARN lines) — but keep
  `realStallDetector?.ingest(...)` FIRST so RealTrafficStallDetector stays fed (it reads the
  raw pre-filter stream). Eliminates the `diskwrites_resource` kill + most storm CPU.
- **Cap `stderr.log`** in `TunnelFileLogger.swift` — it is the ONLY uncapped file sink
  (tunnel-debug 2 MB, singbox.log 4 MB, stderr.log = unbounded → the 28 MB culprit). And
  replace the truncation path's `String(contentsOf:)` full-file-read with a seek+truncate
  (there's already a `truncationKeepOffset` helper) — it currently reads the whole file into
  the ~50 MiB budget on every rollover.
- **`runtime.GOMAXPROCS(1)`** in the NE entrypoint (Tailscale precedent) — cuts per-P
  allocator overhead in a memory-starved extension.

**Libbox rebuild (the baseline lever):**
- `experimental/libbox/memory.go:14` — `SetMemoryLimit(45MiB)` → **35 MiB** (Fable) /
  upstream uses 37.5 (3/4 of 50). Ship 35, measure, raise to 38 if bulk-transfer throughput
  sags at ~50% GC CPU. Keep `SetGCPercent(10)`. Add an exported `SetMemoryLimitBytes(int64)`
  so future tuning is build-free.
- **Delete the default oom-killer append** (`daemon/instance.go:90-98`) OR flip
  `command_server.go:63` `OOMKiller:false` — removes the dispatch source, the ~32/s callback,
  the spam, and the never-disarming timer entirely. Jetsam becomes the honest backstop. The
  backend keeps emitting the 512MB service for LEGACY clients (their libbox still appends the
  default); the new client's ConfigSanitizer strips it.
- Belt-and-suspenders: demote `service/oomkiller/service.go:165,170` `Warn`→`Debug`.
- (Optional, has a caveat) fix the `observable.go:140` bypass to gate on level — BUT
  RealTrafficStallDetector feeds on INFO `open connection` + ERROR dial-timeout lines
  (`RealTrafficStallDetector.swift:249-268`); gating to error blinds its `successfulDials`
  signal. If done, keep config `log.level:"info"` and take the CPU win via the Swift
  file-sink filter instead. Simpler to skip this and do the Swift filter.

**Rebuild mechanics (Fable):** `make lib_install` (pins gomobile) → `make lib_apple` (3-slice
xcframework). Info.plist patch is NOT in build_libbox — it's the manual per-slice step
(reference_libbox_build); skipping fails at App Store *validation*, not runtime. Upload to a
**NEW** release tag (e.g. `libbox-v1.13.5-mem35`), NOT `--clobber` on `libbox-v1.13.5` (keep
the known-good rollback binary); bump the tag in `clients/apple/scripts/fetch-libbox.sh`.

**Verify on-device (the WDA rig):** idle phys ~20-23 MiB (was 26), start line low-30s (was
41), whoer.net storm peak ≤ ~40 MiB with ZERO `memory pressure:` lines and no mid-line log
silence; after a 10-min stress, pull crash reports → zero new cpu_resource/diskwrites/Jetsam.

**Ranked:** (1) Go cap 45→35 [rebuild, biggest]; (2) file-sink ≥WARN + cap stderr.log [client
build, kills 2/3 vectors, no rebuild]; (3) delete default oom-killer + Warn→Debug [rebuild];
(4) SetMemoryLimitBytes export; (5) GOMAXPROCS=1; (6) revert emergencyNoUrltest after
verification. Do NOT remove the 512MB service from the backend — that re-arms pressure-mode
(the 62k-reset bug) at full frequency, since the device sits at 43-47/50.

---

## 2026-07-15 (night) — NE-LOG-SINK-FIX shipped; the "cap stderr.log" bullet above was wrong

Implemented item (2) from the ranked plan above, but re-verified the stderr.log half with Fable
mid-implementation rather than trust the earlier write-up, since capping a file our own Swift
code never writes to (it's a native `LibboxRedirectStderr` fd redirect) needed a real mechanism,
not a guess.

**Finding: "cap stderr.log" was wrong, and worse than a no-op if implemented naively.**
`experimental/libbox/log.go RedirectStderr` doesn't dup2 the process's raw fd 2 — it calls Go's
stdlib `runtime/debug.SetCrashOutput(outputFile, ...)` (confirmed against Go 1.26 runtime source,
`writeErrData` in `runtime/runtime.go`: the crash-fd write is gated on `gp.m.dying > 0 ||
panicking.Load() > 0`). That fires **once**, synchronously, in the dying moments of a fatal Go
runtime error (unrecovered panic, concurrent-map crash, etc.) — never periodically. So:

- A 15s Swift truncation watchdog can't intercept a burst that only happens at process death.
- Truncating afterwards refunds nothing — the diskwrites ledger (if that's even how the field
  28 MB event was charged) was already spent by the time any watchdog could see the file.
- **The trap:** truncating via `.atomic` (temp-file + rename) or any full-file
  `String(contentsOf:)` read would swap the inode or spike memory — either breaks Go's already
  dup'd crash-output fd (next crash silently vanishes) or risks the exact jetsam-adjacent memory
  spike this whole saga is about. Left the file untouched entirely.

**Where the 28 MB actually came from (best-effort, unconfirmed):** `experimental/libbox/setup.go`
forces `debug.SetTraceback("all")` in its `init()`, so *every* fatal crash — not just runtime
internals — dumps **every live goroutine's stack**, not just the crashing one. 227k lines /
~12 lines-per-goroutine ≈ ~19k goroutines at time of death. Under a `GOMEMLIMIT=45MiB` +
`GCPercent(10)` regime, that's a plausible pile-up (blocked/leaked goroutines accumulating under
memory pressure, then one fatal error dumps the whole pile). **Not proven** — the actual trigger
line (the crash header) would need reading the field device's `stderr.log`/`stderr.log.old`
directly, not done this session. Real fix, if the goroutine-pileup theory holds, is upstream of
this file entirely (whatever leaks/blocks goroutines under memory pressure) — separate from
LIBBOX-REBUILD's already-planned memory-cap work, and not yet root-caused.

**What actually shipped (client build, no rebuild, build 1.0.34/136):**
- `ExtensionPlatformInterface.swift`: `writeLogs`/`writeMessage` guard raised INFO(2)→WARN(3);
  `writeDebugMessage` swapped `isVerboseSingboxLine` → new `isBelowWarnSingboxLine` (also drops
  INFO). `realStallDetector.ingest()` still sees every raw line first, unaffected.
- `TunnelFileLogger.swift`: `writeToFile`'s own truncation (the tunnel-debug.log path) switched
  from `String(contentsOf:)` to seek+truncate via the existing `truncationKeepOffset` helper.
  Also **dropped the per-line `fsync`** (`handle.synchronize()`) — Fable-verified it protects
  against kernel panic/power loss, not jetsam SIGKILL (a `write()`'d line survives the process
  dying via the kernel page cache regardless of fsync; same-machine App Group readers see it the
  instant the syscall returns). `logSync()`'s `queue.sync` is what actually protects against a
  SIGKILL racing an unflushed async write — the fsync was pure diskwrites cost for nothing.
- `GOMAXPROCS(1)` **not** done here — Fable confirmed no Swift/Cgo path exists to set it; belongs
  in `experimental/libbox/setup.go`'s `init()` as part of LIBBOX-REBUILD.
- 358 unit tests pass (2 new), full app+extension `xcodebuild build` succeeds.

**Still needed:** on-device WDA-rig verification (whoer.net storm → no new `diskwrites_resource`/
`cpu_resource` crash reports), then LIBBOX-REBUILD.

---

## 2026-07-15 (night) — on-device verification: build 136 HOLDS through the whoer.net storm

Drove the user's iPhone over USB (WDA rig, see `reference_autonomous_iphone_control`) right after
they updated to 1.0.34(136): connected the VPN (Poland/waw1 exit), loaded `whoer.net/ru` in
Safari — the exact leak-test page that killed build 135 in ~4 s — and watched.

**Result: PacketTunnel PID stayed the SAME (2970) for the full ~5.25 min test window** (21
consecutive 15 s memory-watchdog lines, no gap, no restart). `whoer.net` fully loaded and
correctly showed the tunnel's Poland IP (217.182.74.70) — no leak, no failed load. Memory stayed
flat: **phys 29-30 MB, avail 19-20 MB** — comparable to build 135's on-device baseline, well
under the ~50 MB ceiling. Zero `resetting network`, zero `memory pressure: critical`. **Zero new
crash reports of any kind** (`pymobiledevice3 crash pull -m PacketTunnel` — the newest file on
the device is still `cpu_resource-2026-07-14-215042.ips`, from the *previous* day's testing,
nothing from 07-15).

**One new, previously-unseen kernel warning surfaced (not a kill):** ~57 s into the storm,
`kernel[0]: process PacketTunnel[2970] caught waking the CPU 45001 times over ~57 seconds,
averaging 778 wakes/second and violating a limit of 45000 wakes over 300 seconds.` This is the
EXC_RESOURCE **wakeups** limit (a 4th vector, distinct from CPU-time/diskwrites/memory) — the
process is waking the CPU too often (dispatch timers, socket I/O events, etc.), not burning CPU
time or writing to disk. It did **not** result in a kill this time — the PID survived unchanged
for 4+ more minutes after the warning — but it's a live signal worth taking seriously:
`GOMAXPROCS(1)` (already queued for LIBBOX-REBUILD, per Fable's 2026-07-15 note above) directly
addresses wakeup/scheduling overhead and should help here too. Not urgent enough to block
LIBBOX-REBUILD, but worth citing a before/after wakeups count from `sysdiagnose` or the same
kernel log line when that ships.

**Conclusion:** NE-LOG-SINK-FIX is a real, verified fix for the diskwrites_resource + cpu_resource
kill vectors that were killing the extension in ~4 s. LIBBOX-REBUILD remains queued for the
memory-baseline win and now also has a second justification (the wakeups warning).

---

## 2026-07-15 (night) — LIBBOX-REBUILD shipped

Same session, straight after the NE-LOG-SINK-FIX on-device verification above. Rebuilt
`sing-box-fork` (branch `v1.13.5-madfrog`, commit `890a1440`) and its xcframework.

**Go memory cap 45→35 MiB** (`experimental/libbox/memory.go`) — the NE was starting ~41 MiB deep
into its ~50 MiB budget with only ~8 MiB headroom at the old 45 MiB cap; 35 leaves real margin.
Added an exported `SetMemoryLimitBytes(int64)` for build-free future tuning.

**Removed the implicit oom-killer entirely**, not just demoted its logging. Traced the full
call chain: `command_server.go:63` set `OOMKiller: memoryLimitEnabled`, which is always true on
iOS (`SetMemoryLimit(true)` runs at every start) → `daemon/instance.go`'s `newInstance` appended
a bare `{Type: TypeOOMKiller}` service (no `MemoryLimit`) whenever the config didn't already
declare one → `service/oomkiller/service.go`'s `hasTimerMode == false` branch is "pressure-monitor
mode": every `DISPATCH_MEMORYPRESSURE_CRITICAL` event, device-wide, unconditionally calls
`router.ResetNetwork()` — the original 62,756-reset bug from the top of this file. In practice this
branch has been dormant since the backend started emitting an explicit `memory_limit` service
(`common.Any` found one already present, skipped the append) — but it was a live footgun for any
future config path that forgets to include one. Deleted the append block, then deleted the now
fully-dead `oomKiller`/`OOMKiller` field end-to-end (struct field, options field, assignment) —
confirmed via grep it was the *only* call site, so hardcoding it false and then removing the dead
field entirely was safe. A config that wants an oom-killer must declare one explicitly now; jetsam
is the sole implicit backstop.

**Demoted the oom-killer's timer-mode pressure logs Warn→Debug** (`service/oomkiller/service.go`).
These fire on device-wide memory pressure (observed ~32/s under load in the original investigation)
and, now that NE-LOG-SINK-FIX raised the iOS client's file-sink filter to WARN+, would otherwise
flow straight back into the log file the fix was meant to quiet — informational-only lines (timer
mode doesn't act on them, no `ResetNetwork`) don't need to survive at WARN.

**`runtime.GOMAXPROCS(1)`, iOS-only** (`experimental/libbox/setup.go`, gated on `C.IsIos`, not
applied to Android). Added in `init()` — the earliest point the framework's own code runs (dyld
constructor, before `Setup()`/`RedirectStderr`/`CommandServer` creation), matching Fable's
2026-07-15 finding that no Swift/Cgo path can set this. Directly targets the wakes_resource kernel
warning (778 wakes/s vs a 150/s budget) that surfaced during the NE-LOG-SINK-FIX on-device test
above — Tailscale precedent for memory-constrained network extensions.

**Zero server impact, confirmed structurally, not just asserted:** grepped for every importer of
the `daemon` package — only `experimental/libbox/{command_client,command_types,command_server}.go`
(the gomobile client bindings) reference it; the server's `cmd/` binary never does. Separately,
`service/oomkiller/service.go` carries `//go:build darwin && cgo` — it's compiled out of the Linux
server build (`service_stub.go` provides the stub there). So none of these four changes touch the
`sing-box-fork:v1.13.6-userapi` server image; no docker redeploy needed.

**Build process:** `make lib_install` (gomobile/gobind v0.1.12 reinstall) → `make lib_apple` (3
slices: ios-arm64, ios-arm64_x86_64-simulator, macos-arm64_x86_64 — tvOS stripped, not shipped) →
per-slice Info.plist patch (App Store validation, see `reference_libbox_build`) → full
app+extension `xcodebuild build` succeeded, 358 unit tests pass. Uploaded to a **new** GitHub
Release tag `libbox-v1.13.5-mem35` (did **not** `--clobber` `libbox-v1.13.5` — that stays the
rollback binary if anything regresses). `fetch-libbox.sh`'s default `LIBBOX_TAG` bumped; override
with `LIBBOX_TAG=libbox-v1.13.5` to roll back without a re-clone.

**Build 1.0.34(137)** — shipped to TestFlight the same session.

**Still needed:** on-device WDA-rig verification — idle/load phys_footprint before (26/43-47 MiB
on build 136) vs after, another whoer.net storm, zero new crash reports, and specifically whether
the wakes_resource kernel warning recurs.

---

## 2026-07-15 (night) — on-device verification: build 137 confirms the memory-baseline win

Same USB rig, right after the user updated to 1.0.34(137). Connected the VPN (this time landed on
the NL exit, not Poland — server-selection detail, irrelevant to this test), loaded whoer.net,
watched for ~4.5 minutes.

**Memory baseline moved decisively:**

| | build 136 (old libbox, 45 MiB cap) | build 137 (new libbox, 35 MiB cap) |
|---|---|---|
| sing-box start | (not captured) | **11 MB used / 38 MB avail** |
| idle phys | ~26 MB | **~13 MB** |
| under whoer.net load | phys 29-30 MB, avail 19-20 MB | **phys 21-22 MB, avail 27-28 MB** |

Roughly **halved** the idle footprint and nearly **doubled** the headroom under the same load. PID
stayed the same throughout (no restart), zero `resetting network`, zero `memory pressure: critical`,
**zero new crash reports** (`pymobiledevice3 crash pull` — still nothing from 07-15).

**The wakes_resource kernel warning recurred but at a much lower rate: 220 wakes/s (was 778/s on
136), still above the ~150/s budget that triggers the log line.** One important nuance found this
run: **Safari itself independently triggered the identical warning** (`MobileSafari[3564] caught
waking the CPU ... averaging 279 wakes/second`) while sitting on the same leak-test page — meaning
this warning is not purely a PacketTunnel-specific defect; some of it is inherent to the page/test
methodology (and possibly the WDA driving overhead itself). `GOMAXPROCS(1)` measurably helped
(778→220, ~3.5×) but didn't eliminate the warning. Not treated as a blocker — the process survived
both times regardless, and the warning has never once resulted in an observed kill.

**Conclusion:** LIBBOX-REBUILD delivered the memory-baseline win it was queued for. Combined with
NE-LOG-SINK-FIX, both the diskwrites/cpu kill vectors (fixed same session) and the memory-headroom
problem (fixed this rebuild) that drove the whole 2026-07-14/15 saga are now addressed and
on-device verified. The wakes_resource signal is downgraded from "new kill vector" to "a soft
signal worth another before/after data point someday, not urgent" — it never killed anything in
either test and turned out to be partly shared with an unrelated app under the same test
conditions.
