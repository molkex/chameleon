# CODEX Prompt — Audit iOS/Mac MadFrog VPN app

**Copy the whole block below into CODEX as a single prompt.**

---

## Context

You are auditing a **production VPN client** for iOS and macOS called **MadFrog VPN** (bundle IDs `com.madfrog.vpn` and `com.madfrog.vpn.mac`, App Store target). Source tree:

```
apple/
├── ChameleonVPN/        # iOS app (shared SwiftUI views + models)
├── ChameleonMac/        # macOS app (Info.plist, entitlements only; code lives in ChameleonVPN)
├── PacketTunnel/        # iOS NEPacketTunnelProvider extension
├── PacketTunnelMac/     # macOS equivalent
├── Shared/              # Cross-target helpers (ConfigSanitizer, Constants, Logger, PlatformDevice)
└── Frameworks/Libbox.xcframework   # sing-box Go library
```

Stack: Swift 6, SwiftUI (iOS 17+ / macOS 14+), NetworkExtension, StoreKit 2, sing-box 1.13 (vendored via Libbox.xcframework). Auth via Sign in with Apple. Payments: Apple IAP (StoreKit 2) and external FreeKassa (SBP/card) via `UIApplication.shared.open` to Safari. Backend: `https://madfrog.online` (Go + Postgres + Redis).

## Goal

Produce an **actionable vulnerability / bug report** for the Apple apps. Assume this will be read by the developer *and* by an App Store reviewer. Prefer concrete file/line references over generic advice.

## Scope — what to audit

### 1. Security-critical (VPN-specific)
- **DNS leaks**: is every DNS query routed through the tunnel? Check `clientconfig.go` is not relevant here — look at how the iOS app consumes the config (route rules, `dns_remote`, `auto_detect_interface`).
- **Kill-switch behaviour**: when the tunnel drops, does traffic fail closed? `NEVPNProtocol.includeAllNetworks`, `excludeLocalNetworks`, on-demand rules.
- **Config tampering**: `ConfigSanitizer.swift` is meant to strip dangerous fields from server-supplied sing-box config. Find bypasses (fields it misses, path traversal, oversized payloads).
- **Keychain / App Group storage**: what secrets live in `ConfigStore.swift` / `AppConstants.sharedContainerURL`? Are any secrets written to UserDefaults or plain files that get indexed by Spotlight or backed up to iCloud?
- **JWT / token handling** (`ConfigStore.accessToken`, `refreshToken`): stored where? Refresh-on-401 logic in `APIClient.swift`. Race conditions.
- **Sign in with Apple**: `AppState.signInWithApple` — is the identity token validated client-side for audience before sending? Is the server's response validated? Can a spoofed 200 log the user in without a real account?

### 2. Network / TLS
- `NSAllowsArbitraryLoads = true` in `Info.plist` — why, and what's the blast radius? List every `URL(string:)` call; confirm they're all https to madfrog.online or apple/storekit hosts.
- Certificate pinning — not implemented; is that OK for a VPN client?
- `AppConfig.fallbackBaseURL = "http://162.19.242.30"` — plaintext HTTP to origin. When is it used? Exploitable?
- `WebPaywallView.swift` opens external Safari via `UIApplication.shared.open`. Confirm no JS/URL injection from server-provided `paymentURL`.

### 3. Payments / App Store compliance
- **Guideline 3.1.1 (IAP bypass)**: `WebPaywallView` collects plan + email + payment method in-app, then opens Safari. Is the in-app UI phrased as a "Buy" CTA (reject risk) or as "continue on website" (safe)? Cite strings/screens.
- **Receipt / StoreKit 2 flow** (`SubscriptionManager.swift`): replay protection, sandbox vs prod audience, transaction finish logic.
- **Restore purchases**: works from all paywalls?
- **Account deletion** (`AppState.deleteAccount`): does it actually wipe local state? Keychain? sharedContainerURL? What stays after delete?

### 4. Apple review red flags (aside from IAP)
- Privacy manifest / required-reason API declarations — present? Which APIs (file timestamp, user defaults, etc) require a declared reason?
- Export compliance (`ITSAppUsesNonExemptEncryption=false`) — accurate given that we use TLS & VLESS Reality?
- Minimum OS, device support — consistent across iOS + Mac targets?
- Localization parity: RU is primary, EN strings — any placeholders, unlocalized user-facing text?
- Accessibility: minimum — VoiceOver labels on primary VPN toggle and server picker.

### 5. Crash / stability
- Force-unwraps (`!`) in code paths reachable at runtime.
- Unhandled throwing functions that surface as silent failures.
- `Task.detached` / concurrency races — especially around VPN status transitions (`VPNManager.swift`, `AppState.toggleVPN`).
- Retry / watchdog loops that can run forever (`AppState.swift` — look at `preflightProbe`, `handleForeground`, status observer).
- Memory leaks: strong self captures in `Task { ... }`, notification observers, delegate cycles.

### 6. Mac-specific (brand-new target)
- `MenuBarContent.swift` — fresh code. Actions on a disconnected VPN, double-click on tray icon, re-entry while `isLoading`.
- `PlatformViewExtensions.swift`, `PlatformDevice.swift`, `PlatformMainApp.swift` — correctness of `#if os(macOS)` guards; any iOS-only call that slipped through.
- `NSWorkspace.shared.open` for payment redirects — same compliance story as iOS `UIApplication.shared.open`.
- Sandbox entitlements (`ChameleonMac.entitlements`): only necessary entries present? No overbroad privileges?
- `PacketTunnelMac` App Group mismatch with main app would break tunnel — confirm both sides read/write the same `group.com.madfrog.vpn`.

### 7. Code quality / debt
- Dead code / unused files.
- TODOs and `FIXME` in source.
- Inconsistent error messages (user-facing strings localized but hardcoded in some places).
- Logger hygiene: `os.Logger` `privacy: .public` on PII fields (emails, tokens) would leak to Console.app — flag every instance.

## Methodology

1. **Static pass first**: read every file under `apple/` (excluding `build*/`, `Frameworks/`, `*.xcuserdata`). Favor grep/ripgrep over running the app.
2. **Threat-model pass**: assume the backend is hostile. What data can a malicious `/config` response do? What about a malicious StoreKit transaction? FreeKassa redirect?
3. **Compile-time verification**: when you flag a concurrency or memory issue, cite the Swift language feature that makes it a bug (e.g., "this `@MainActor` isolated function captures a non-sendable `self` in `Task.detached`").

## Output format

For every finding, use this exact structure:

```
### [SEVERITY] Short title
**File:** `apple/path/to/File.swift:LINE`
**Category:** security | compliance | crash | leak | debt | a11y
**Issue:** 1-3 sentences, concrete.
**Reproduction / impact:** when does this bite a user, and what's the blast radius?
**Fix:** concrete change. If trivial, include a diff. If non-trivial, outline the approach.
```

Severities: `CRITICAL` (data leak, crash on main flow, App Store reject guaranteed), `HIGH` (reject likely, or VPN integrity affected), `MEDIUM` (polish / UX / review-notes risk), `LOW` (debt, nice-to-have).

Group findings by severity, CRITICAL first. At the end, include a "**Summary**" section: top-3 things to fix before the next TestFlight build, and top-3 things the reviewer may call out.

Do **not** recommend changes to server-side code or backend — this audit is for the Apple client only.

Do **not** flag things that are actually correct just because they look unusual — if `NSAllowsArbitraryLoads=true` is needed for the FreeKassa redirect flow to work through external Safari, say so and move on.

Be ruthless and specific.
