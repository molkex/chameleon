# Security Audit — Chameleon VPN iOS/macOS Client

**Date:** 2026-04-22  
**Auditor:** Claude Security Reviewer  
**Scope:** `apple/` directory — Swift 6, SwiftUI, NetworkExtension, libbox/sing-box, StoreKit 2  
**App state:** TestFlight, preparing for paid public launch via FreeKassa  

---

## Executive Summary

No CRITICAL vulnerabilities found. The architecture is generally sound — JWT tokens in Keychain, server-side payment verification, no plaintext credentials. Three HIGH issues require attention before public launch: a blanket TLS bypass on fallback paths, `NSAllowsArbitraryLoads` in both iOS and macOS Info.plist, and verbose debug infrastructure (VPN config written to disk in cleartext in the shared container, server IPs/UUIDs in log files accessible from unlocked device).

---

## Findings

---

### [HIGH] Insecure TLS on Fallback API Paths

**File:** `apple/ChameleonVPN/Models/APIClient.swift:76-86, 122-149`

**What:** `InsecureDelegate` accepts any server certificate (including self-signed, expired, or attacker-controlled) for all requests routed to `AppConfig.russianRelayURL` (`http://185.218.0.43`) and `AppConfig.fallbackBaseURL` (`http://162.19.242.30`). Both fallback URLs also use plain HTTP.

```swift
private class InsecureDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: ...) {
        completionHandler(.useCredential, URLCredential(trust: trust))  // trusts anything
    }
}
```

**Attack scenario:** Attacker on the same network (coffee shop, ISP MITM in Russia) intercepts the fallback request (HTTP, no TLS verification). They respond with a crafted `AuthResult` containing a fake `access_token`/`refresh_token`, or a crafted VPN config. Because the fallback fires silently after the primary Cloudflare URL fails, the user never sees a warning. The malicious config is saved and loaded into libbox on next VPN connect.

**Severity reasoning:** The comment justifies this by saying VLESS Reality encryption protects the VPN tunnel itself — but this is the API channel (auth tokens, VPN config delivery), not the VPN tunnel data. A malicious config injected here bypasses VLESS Reality entirely.

**Fix options (choose one):**
1. **Preferred:** Pin the exact self-signed certificate of the relay and direct-IP endpoints. Store the certificate's SHA-256 public key hash in `Constants.swift` and verify it in `InsecureDelegate`.
2. **Acceptable:** Install a proper certificate on both fallback hosts (Let's Encrypt works on IP with a reverse-proxy fronting it, or use a domain). Remove `InsecureDelegate` entirely — `URLSession` default handling then validates TLS normally.
3. **Minimum:** At least switch fallback URLs from `http://` to `https://` and keep certificate validation for any response that writes to Keychain or saves a VPN config.

---

### [HIGH] NSAllowsArbitraryLoads — ATS Disabled Globally

**Files:**  
- `apple/ChameleonVPN/Info.plist:35-38`  
- `apple/ChameleonMac/Info.plist:35-38`

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

**What:** This disables Apple's App Transport Security entirely for all connections from the app process. Any `URLSession` call in the main app can now connect to arbitrary HTTP endpoints with no TLS, no forward-secrecy requirements, etc.

**Attack scenario:** The primary concern is that this is a silent security net removal. Combined with the InsecureDelegate above, there is no TLS enforcement layer. In isolation (without InsecureDelegate), this is a configuration smell — iOS ATS would otherwise enforce TLS 1.2+ and valid certificates even if the developer forgot.

**Fix:** Replace with domain-specific exceptions. The only hosts that need HTTP are the direct-IP fallbacks. Example:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
    <key>NSExceptionDomains</key>
    <dict>
        <key>162.19.242.30</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
            <key>NSIncludesSubdomains</key>
            <false/>
        </dict>
        <key>185.218.0.43</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
            <key>NSIncludesSubdomains</key>
            <false/>
        </dict>
    </dict>
</dict>
```

This keeps the primary URL (`madfrog.online`) under full ATS enforcement.

---

### [HIGH] VPN Config Saved in Cleartext to Shared Container (Two Copies)

**Files:**  
- `apple/Shared/ConfigStore.swift:94-116` — writes to `singbox-config.json`  
- `apple/PacketTunnel/ExtensionProvider.swift:199-201` — writes additional `sanitized-config.json`  
- `apple/ChameleonVPN/Models/AppState.swift:236` — also stored in UserDefaults under key `startOptions`

**What:** The sing-box config (containing the user's UUID, server IP, Reality public key, and protocol details) is saved in three locations in the App Group shared container:
1. `singbox-config.json` (file)
2. `sanitized-config.json` (debug copy written during every tunnel start)
3. UserDefaults key `startOptions` (serialized as plist in the App Group's `Library/Preferences/`)

The App Group container is readable by any app on the device that shares the same Team ID and App Group identifier — but in practice on iOS this is limited to apps signed by the same team (only your apps). On a jailbroken device, all three locations are trivially accessible.

**Attack scenario (physical access / jailbreak):** With a jailbroken device or iTunes filesystem backup (if unencrypted), an attacker reads the config file and extracts the user's VLESS UUID. This UUID is the only credential needed to authenticate to the VPN server — they can then connect as the user and exhaust their subscription, or identify their user account.

**Note on `sanitized-config.json`:** This debug copy is written on every tunnel start in production (no `#if DEBUG` guard). It serves no operational purpose — it is only useful for diagnosing startup issues. It should be removed from production builds.

**Fix:**
1. Remove the `sanitized-config.json` write in `ExtensionProvider.startSingBox()` from production builds (wrap in `#if DEBUG`).
2. The `singbox-config.json` in the shared container is architecturally necessary (the extension needs to read it). Accept this as the threat model for now, but consider whether the Reality public key and UUID could be stored separately in Keychain and injected only at tunnel-start time, reducing the surface of what the file contains.
3. The UserDefaults `startOptions` copy is also necessary for On Demand reconnect. It is plist-encoded and stored alongside `singbox-config.json` — no additional exposure.

---

### [MEDIUM] Keychain Accessibility: kSecAttrAccessibleAfterFirstUnlock Without kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

**File:** `apple/Shared/KeychainHelper.swift:19`

```swift
add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
```

**What:** `kSecAttrAccessibleAfterFirstUnlock` allows the Keychain item to be included in iCloud Keychain sync and iTunes backups. The more restrictive `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` restricts items to the current device only, preventing extraction via backup or Keychain sync to another device.

Stored under this accessibility: `accessToken`, `refreshToken`, `username`.

**Attack scenario:** If a user performs an unencrypted iTunes backup (or iCloud backup, since Keychain items with this attribute sync), an attacker with access to that backup can extract the JWT refresh token and replay it against the backend to obtain a new access token.

**Fix:** Change to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for all three credentials. The PacketTunnel extension can still read them (the "after first unlock" portion still applies) since it runs in the same device context.

```swift
add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

---

### [MEDIUM] Debug Logs Contain Server IPs, UUIDs, and VPN Config Size — No Authentication Required to View

**File:** `apple/ChameleonVPN/Views/DebugLogsView.swift` (full file), `apple/Shared/TunnelFileLogger.swift`

**What:** The debug log view is accessible from Settings without any authentication gate. It displays and allows sharing/exporting of:
- Server IPs from network tests (162.19.242.30, 147.45.252.234, 185.218.0.43 hardcoded in `testAllEndpoints()`)
- Full libbox/sing-box logs routed through `ExtensionPlatformInterface.writeLogs()`, which include outbound connection destinations, DNS queries, and protocol handshake details
- Diagnostics including `sharedContainerPath` (absolute path to the App Group container)
- The `buildClaudeReport()` function exports structured data including config version and VPN uptime

**Attack scenario (physical access):** An attacker with access to an unlocked device opens Settings → Diagnostics → Debug Logs → Share, and receives a complete log dump. Depending on what happened during that session, this can include:
- DNS resolution attempts revealing the user's browsing destinations
- Server hostname/IP resolution details
- The shared container path (useful for targeted file extraction on jailbroken devices)

The network test tab also hardcodes all internal server IPs and ports in the UI, making them visible to anyone who opens the screen.

**Fix:**
1. Gate the Diagnostics section in SettingsView behind Face ID / Touch ID authentication (use `LAContext.evaluatePolicy`). One call on entry is sufficient.
2. Remove the hardcoded internal server IPs from `testAllEndpoints()`, or dynamically derive them from the parsed config rather than embedding them as string literals.
3. Ensure `TunnelFileLogger` does not log connection targets at INFO level in Release builds (wrap verbose logging in `#if DEBUG`).

---

### [MEDIUM] FreeKassa Payment URL Opened Without Domain Validation

**File:** `apple/ChameleonVPN/Views/WebPaywallView.swift:287-289`

```swift
if let url = URL(string: result.paymentURL) {
    await PlatformURLOpener.open(url)
}
```

**What:** The `paymentURL` returned by the backend is opened in external Safari without checking that it belongs to an expected domain (e.g., `freekassa.ru`, `pay.freekassa.ru`). If the backend is compromised or the API response is tampered with (possible via the insecure fallback path described in Finding 1), an attacker can supply any URL.

**Attack scenario:** Compromised backend or MITM on the fallback API path returns `"payment_url": "https://evil.example/phishing"`. The app opens it in Safari, presenting the user with a convincing phishing page. Because the payment flow legitimately opens an external page, the user has no reason to distrust it.

**Fix:** Whitelist accepted payment URL domains before opening:

```swift
let allowedHosts: Set<String> = ["freekassa.ru", "pay.freekassa.ru", "madfrog.online"]
if let url = URL(string: result.paymentURL),
   let host = url.host, allowedHosts.contains(host) {
    await PlatformURLOpener.open(url)
} else {
    errorMessage = "Некорректный адрес платежной страницы"
}
```

---

### [MEDIUM] libbox Debug Mode Enabled in Production Extension

**File:** `apple/PacketTunnel/ExtensionProvider.swift:153`

```swift
setupOptions.debug = true
```

**What:** `LibboxSetupOptions.debug = true` is set unconditionally in `startSingBox()`, which runs in production. In libbox/sing-box, debug mode enables verbose logging at TRACE/DEBUG level. This means all DNS queries, connection establishment events, and outbound selection decisions are logged to `tunnel-debug.log` and `stderr.log` in the shared container.

**Attack scenario:** This compounds the debug log finding above. The volume and detail of logged data is significantly higher than with debug disabled, increasing the information available to an attacker with device access.

**Fix:**
```swift
setupOptions.debug = false  // or: setupOptions.debug = AppConfig.isDebugBuild
```

Also set `setupOptions.logMaxLines` only in debug builds.

---

### [LOW] Universal Link Handler Logs Full URL Path

**File:** `apple/ChameleonVPN/ChameleonApp.swift:101`

```swift
TunnelFileLogger.log("ChameleonApp: universal link \(path)", category: "ui")
```

**What:** The full URL path (e.g., `/app/payment/order-12345`) is written to the tunnel debug log, which is persisted to disk and accessible from the debug log view. This logs payment order IDs.

**Attack scenario:** Low severity — order IDs from FreeKassa are not secret enough to constitute a meaningful attack surface. However, they should not persist in diagnostic logs.

**Fix:** Log only the path prefix: `TunnelFileLogger.log("ChameleonApp: universal link /app/payment/*", category: "ui")`

---

### [LOW] Username (VPN Account Identifier) Logged at INFO Level

**Files:**  
- `apple/ChameleonVPN/Models/AppState.swift:147, 213, 273`

```swift
AppLogger.app.info("autoRegister: registered as \(result.username)")
AppLogger.app.info("reRegisterDevice: registered as \(result.username)")
AppLogger.app.info("signInWithApple: username=\(result.username), isNew=\(result.isNew ?? false)")
```

**What:** The VPN username (which doubles as an account identifier) is logged at `os.log` INFO level. On iOS, `os.log` INFO entries are not private — they are readable by the system and can appear in Console.app on a paired Mac. Note: the `privacy: .public` modifier is intentionally used in some log calls, which is appropriate, but these specific calls do not use it and log plain strings.

**Attack scenario:** Very low in practice — `os.log` requires a paired developer Mac or explicit log export. But it's a minor hygiene issue.

**Fix:** Either redact: `AppLogger.app.info("registered as \(result.username, privacy: .private)")` or use the explicit privacy modifier, or simply omit the username from these log lines (log "registered successfully" instead).

---

### [LOW] Telegram Activation Code Sent Without Auth Context

**File:** `apple/ChameleonVPN/Models/APIClient.swift:188-220`

**What:** `activateCode()` sends a Telegram activation code over the primary session (with TLS validation) — this is fine. However, the code is a short user-supplied string sent as POST body. There is no rate limiting on the client side.

**Attack scenario:** Automated code guessing is a backend concern, not a client concern. No client-side fix needed. Flag is for awareness only — ensure the backend enforces rate limiting on this endpoint.

**Severity:** LOW — client cannot be expected to prevent brute-force; this is properly a backend responsibility.

---

## Non-Issues (Checked, Not Flagged)

1. **JWT tokens in Keychain** — `accessToken` and `refreshToken` are stored in Keychain via `KeychainHelper`. Correct.
2. **Apple Sign-In** — Identity token forwarded to backend server-side for verification. Client does not validate the JWT itself. This is the correct architecture.
3. **StoreKit 2 receipts** — Signed JWS is sent to backend for validation against Apple's root CA. Client-side receipt validation is correctly absent.
4. **IPC between app and extension** — Uses libbox Unix socket (`command.sock`) scoped to the App Group shared container. Access is restricted to apps in the same App Group (same team ID). No auth needed on the socket because the threat model (same-team apps) is acceptable.
5. **App Group shared UserDefaults** — Contains non-sensitive preferences (routing mode, server tag, subscription expiry date, grpcAvailable flag). The JWT tokens are NOT in UserDefaults — they are in Keychain. Correct.
6. **Entitlements** — iOS entitlements are minimal and appropriate: `packet-tunnel-provider`, `application-groups`, `applesignin`, `associated-domains`. No over-privileged capabilities.
7. **Kill-switch** — Not explicitly implemented (no `NEOnDemandRule` with interface restrictions), but the tunnel architecture is full-tunnel (all routes via TUN). When the tunnel drops, iOS reverts to direct routing. This is standard for VPN apps and not configurable from the extension side without OS support. Acceptable for the current product scope.
8. **IPv6 leaks** — `buildTunnelSettings()` only configures `ipv6Settings` if the config provides IPv6 addresses. Current servers don't support IPv6 forwarding, so IPv6 is intentionally not routed through the tunnel. If IPv6 is active on the network, IPv6 traffic bypasses the VPN — but this appears to be a deliberate architectural choice, not an oversight.
9. **DNS leaks** — DNS is routed through the tunnel via `dnsSettings.matchDomains = [""]`. Correct.
10. **Deeplink hijacking** — Universal link handler validates `url.host == "madfrog.online"` before processing. Path must start with `/app/payment/`. Correct.
11. **CSRF on FreeKassa payment** — The payment is initiated from the app with a valid Bearer token; the FreeKassa redirect is handled server-side via webhook. No CSRF surface exists on the client.
12. **Hardcoded secrets** — No API keys, passwords, or private keys found in the Swift source code. `fallbackBaseURL` and `russianRelayURL` are infrastructure addresses, not secrets.

---

## Summary Table

| # | Severity | Issue | File |
|---|---|---|---|
| 1 | HIGH | TLS bypass on fallback API paths (InsecureDelegate + HTTP URLs) | APIClient.swift:76 |
| 2 | HIGH | NSAllowsArbitraryLoads globally enabled | Info.plist (iOS + macOS) |
| 3 | HIGH | VPN config in cleartext on disk (two copies, incl. debug copy in prod) | ExtensionProvider.swift:200, ConfigStore.swift:112 |
| 4 | MEDIUM | Keychain accessibility allows backup/iCloud sync of JWT tokens | KeychainHelper.swift:19 |
| 5 | MEDIUM | Debug logs with server IPs/UUIDs accessible without authentication | DebugLogsView.swift, TunnelFileLogger.swift |
| 6 | MEDIUM | Payment URL opened without domain whitelist validation | WebPaywallView.swift:287 |
| 7 | MEDIUM | libbox debug mode enabled in production | ExtensionProvider.swift:153 |
| 8 | LOW | Universal link logs full payment path including order ID | ChameleonApp.swift:101 |
| 9 | LOW | VPN username logged at INFO level in os.log | AppState.swift:147, 213, 273 |
| 10 | LOW | Activation code endpoint has no client-side rate limiting | APIClient.swift — backend concern |
