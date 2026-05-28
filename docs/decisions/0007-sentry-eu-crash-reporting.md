---
title: Sentry (EU region) for crash reporting, with strict-privacy defaults
date: 2026-05-28
status: active
tags: [ios, macos, observability, privacy, crash-reporting]
---

# 0007 — Sentry EU crash reporting

## Context

LAUNCH-03 in [`docs/roadmap.yaml`](../roadmap.yaml) calls out that the iOS and macOS apps ship without a crash-reporter. Best estimate from the App Store Connect Crashes tab is that we miss ~5% of crashes — Apple only surfaces crashes whose users opted into "Share With App Developers" in Settings, and symbolication on ASC's side is intermittently broken for our (`Libbox.xcframework`-linked) binaries. We want symbolicated stack traces for every crash, with zero PII, on a vendor whose jurisdiction matches our privacy posture — we ship a VPN under an EU-flavoured Russian sole-proprietorship (ИП), and our users explicitly pay us to *not* leak data.

## Decision

Adopt **[Sentry](https://sentry.io)** (sentry-cocoa 8.x SPM package), pointed at the **EU region** (`de.sentry.io`, hosted by Hetzner in Falkenstein, Germany — same datacentre region as our NL exit). Initialisation lives in [`clients/apple/MadFrogVPN/Models/CrashReporter.swift`](../../clients/apple/MadFrogVPN/Models/CrashReporter.swift), called from `MadFrogVPNApp.init()` before any other startup work so an early-launch crash is still captured.

Strict-privacy options:

- `sendDefaultPii = false` — Sentry's default would attach client IP and device name to every event. Both are clear PII for a VPN brand.
- `enableAutoSessionTracking = false` — no daily MAU beacon.
- `tracesSampleRate = 0` — no performance traces. (We can flip a sample rate on later if we ever need them; today we don't, and any sampled span risks capturing URLs.)
- `attachStacktrace = true` — the whole point.
- `beforeSend` scrubs every outgoing event:
  - `event.user = nil` (drop any identifier).
  - `event.request.url` — query string + fragment stripped.
  - `event.request.queryString = nil`.
  - `event.context["device"]["name"]`, `boot_time`, `device_unique_identifier` removed.
  - `event.serverName = ""` (hostname leak; on macOS this is the user-chosen Computer Name).
- DSN is read from `Info.plist` key `SENTRY_DSN` at runtime, populated from an xcconfig / CI secret at build time. **Empty DSN ⇒ `start()` is a no-op.** Open-source clones / dev builds emit nothing.

Scope:

- Linked into **MadFrogVPN (iOS)** + **MadFrogVPNMac** only.
- **NOT** linked into `PacketTunnel` / `PacketTunnelMac`. The Network Extension process has a ~15 MB resident-memory ceiling on iOS, and any non-essential dependency risks OOM-kill mid-tunnel. Crashes inside the extension still surface as `NEVPNStatus` transitions which the main app already maps to user-visible errors.

## Alternatives considered

| Vendor | Why rejected |
|---|---|
| **TelemetryDeck** | No symbolicated native stack traces (the whole point of crash reporting). Great for product analytics, wrong tool for crashes. |
| **Bugsnag** | Free tier caps at 7,500 events/month; we'd hit that on a bad sing-box update day. Paid plans expensive at our scale. |
| **Firebase Crashlytics** | Pulls in the full Firebase SDK (~10 MB binary), forces a Google ecosystem dependency, and Google's data-residency story for free-tier projects is "US" with no EU opt-in. Wrong jurisdiction for a privacy-aligned VPN. |
| **Roll our own MetricKit pipeline** | `MXCrashDiagnostic` payloads land 24 h late, are batched only on charge+wifi, and need server-side symbolication infra we'd have to build. Maybe later as a free supplement, not as the primary signal. |

## Consequences

- **Binary size:** sentry-cocoa 8.x adds ~1.5 MB to the IPA (release, ARM64, after stripping). Negligible for our use case.
- **EU jurisdiction:** events stored in Frankfurt under Sentry GmbH; GDPR applies, no US Cloud Act exposure. App Privacy declaration unchanged — Apple's "Other Diagnostic Data" category already covers crash reports.
- **DSN handling:** the DSN itself is not a secret in the sense of leaking PII (it's a write-only ingest endpoint), but committing one would give anyone with a repo clone the ability to fill our quota. Build-time injection avoids that and also keeps forks from accidentally reporting to our project.
- **Future broadening:** if/when we want richer signal (breadcrumbs of user actions, performance spans), this lands as a follow-up ADR with an explicit "user opt-in" gate, not a default-on flip.

## Status

Active. Re-evaluate after one release cycle (~4 weeks): are we actually catching crashes that ASC misses? Is the scrubbing complete? If a sensitive field slips through, write an `incidents/` post-mortem and tighten `beforeSend`.
