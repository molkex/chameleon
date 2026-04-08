# Chameleon VPN -- Detailed Architecture Document

Last updated: 2026-04-05

---

## Table of Contents

1. [File Map](#file-map)
2. [App Lifecycle](#app-lifecycle)
3. [API Communication](#api-communication)
4. [Config Generation](#config-generation)
5. [VPN Connection](#vpn-connection)
6. [DNS Resolution](#dns-resolution)
7. [Server Selection](#server-selection)
8. [Shared Utilities](#shared-utilities)
9. [Data Models](#data-models)
10. [Known Issues](#known-issues)

---

## File Map

### iOS App (`apple/`)

| File | Purpose |
|---|---|
| `Shared/Constants.swift` | `AppConfig` (URLs, IDs), `AppConstants` (file paths, keys, computed URLs) |
| `ChameleonVPN/ChameleonApp.swift` | `@main` entry point, creates `AppState`, calls `initialize()` on appear |
| `ChameleonVPN/Models/AppState.swift` | Central `@Observable` state -- init flow, VPN toggle, server selection |
| `ChameleonVPN/Models/APIClient.swift` | HTTP calls to backend -- register, fetch config, Apple Sign-In, fallback chain |
| `ChameleonVPN/Models/ConfigStore.swift` | Config file I/O in App Group, Keychain credentials, server parsing |
| `ChameleonVPN/Models/VPNManager.swift` | `NETunnelProviderManager` wrapper -- connect/disconnect/status |
| `ChameleonVPN/Models/CommandClient.swift` | gRPC command client via libbox Unix socket -- live stats, server groups |
| `ChameleonVPN/Models/ServerGroup.swift` | `ServerItem`, `ServerGroup`, `CountryGroup` data models |
| `ChameleonVPN/Views/MainView.swift` | Main UI -- connect button, status, server selector, timer, debug |
| `ChameleonVPN/Views/DebugLogsView.swift` | Debug log viewer (tunnel log, stderr, diagnostics) |
| `PacketTunnel/PacketTunnelProvider.swift` | Thin subclass of `ExtensionProvider` |
| `PacketTunnel/ExtensionProvider.swift` | VPN extension -- sing-box lifecycle via `LibboxCommandServer` |
| `PacketTunnel/ExtensionPlatformInterface.swift` | Bridges sing-box Go engine to iOS `NEPacketTunnelProvider` |
| `Shared/ConfigSanitizer.swift` | Sanitizes sing-box JSON for iOS (currently a passthrough) |
| `Shared/KeychainHelper.swift` | Simple Keychain CRUD (save/load/delete) |
| `Shared/Logger.swift` | `AppLogger` -- os.log Logger for app, tunnel, network categories |
| `Shared/TunnelFileLogger.swift` | File-based logger for PacketTunnel extension debugging |
| `Shared/RunBlocking.swift` | Bridges async/await to synchronous Go callbacks via DispatchSemaphore |
| `Shared/StringUtils.swift` | Russian noun declension helpers (day, server) |

### Backend (Rust)

| File | Purpose |
|---|---|
| `chameleon-apple/src/lib.rs` | Route mounting: `/api/v1/mobile`, `/api/mobile` (legacy), `/sub`, `/webhooks` |
| `chameleon-apple/src/mobile/mod.rs` | Mobile API sub-router: auth, config, shield, speedtest, subscription, support, telemetry |
| `chameleon-apple/src/mobile/auth.rs` | Auth handlers: Apple Sign-In, device registration, token refresh, activation |
| `chameleon-apple/src/mobile/config.rs` | Config handler: `GET /config?username=X&mode=Y` returns sing-box JSON |
| `chameleon-vpn/src/singbox.rs` | `generate_config()` -- builds complete sing-box client JSON |
| `chameleon-vpn/src/protocols/types.rs` | `Protocol` trait, `ServerConfig`, `UserCredentials`, `OutboundOpts` |
| `chameleon-vpn/src/protocols/registry.rs` | `ProtocolRegistry` -- all 8 protocols initialized from Settings |
| `chameleon-vpn/src/protocols/vless_reality.rs` | VLESS Reality (TCP/XHTTP/gRPC) -- inbounds, outbounds, client links |
| `chameleon-vpn/src/protocols/hysteria2.rs` | Hysteria2 (UDP/QUIC) -- sing-box outbound generation |
| `chameleon-vpn/src/engine.rs` | `ChameleonEngine` -- xray config building, server config parsing |
| `chameleon-config/src/lib.rs` | `Settings` struct -- all env vars, validation |

---

## App Lifecycle

### 1. Launch Sequence

```
ChameleonApp.init()
  -> creates AppState (with ConfigStore, APIClient, VPNManager, CommandClientWrapper)
  -> .task { await appState.initialize() }
```

`AppState.initialize()` performs these steps in order:

1. **`repairConfigIfNeeded()`** -- Detects corrupted configs that have only a single direct outbound (no selector/urltest). If corrupted, deletes the config file and clears UserDefaults `startOptionsKey`. This forces a fresh download from the API.

2. **`configStore.parseServersFromConfig()`** -- Reads the cached sing-box config JSON from `AppConstants.configFileURL` (in App Group container). Parses outbounds to build `[ServerGroup]` for the UI. Looks for `selector` and `urltest` outbound types, and extracts their member tags as `ServerItem`s. Falls back to creating a synthetic "Proxy" selector from standalone proxy outbounds if no groups found.

3. **`vpnManager.load()`** -- Loads existing `NETunnelProviderManager` from preferences. Does NOT create or save one (no permission prompt). If an existing manager is found, starts observing VPN status via `NEVPNStatusDidChange` notification.

4. **If VPN is already connected** -- Connects the `commandClient` to receive live stats.

5. **Auto-register if no username** -- If `configStore.username` is nil (first launch), calls `autoRegister()`:
   - `apiClient.registerDevice()` sends `POST /api/mobile/auth/register` with the device's `identifierForVendor` UUID
   - Backend creates a user with trial expiry (default 7 days), generates vpn_username, vpn_uuid, vpn_short_id
   - Stores `accessToken`, `refreshToken`, `username` in Keychain
   - Immediately calls `fetchAndSaveConfig()` to download sing-box config

6. **Silent config update** -- If username exists (returning user), calls `silentConfigUpdate()` to refresh the config from the backend. Errors are logged but don't block the UI.

### 2. VPN Toggle (`toggleVPN()`)

**Disconnect path:**
1. `commandClient.disconnect()` -- tears down gRPC stats connection
2. `vpnManager.disconnect()` -- disables On Demand, then calls `stopVPNTunnel()`

**Connect path (has cached config):**
1. Reads config from `configStore.loadConfig()` (file at `AppConstants.configFileURL`)
2. Calls `vpnManager.connect(configJSON:)` -- passes config as `startTunnel` option
3. Fires background `Task` for `silentConfigUpdate()` to refresh config for *next* connection

**Connect path (no cached config):**
1. Shows loading indicator
2. Calls `silentConfigUpdate()` to fetch config from API
3. If config now exists, proceeds to connect as above

### 3. Server Switch (`selectServer()`)

1. Updates `configStore.selectedServerTag` (UserDefaults)
2. Updates local `servers` array for immediate UI reflection
3. If VPN is connected and tag changed:
   - Builds config in memory with the selector's `default` changed to new server tag (`buildConfigWithSelector()`)
   - Writes updated config to UserDefaults `startOptionsKey` (for On-Demand reconnects)
   - Does NOT modify the config file on disk
   - Disconnects: `commandClient.disconnect()` -> `vpnManager.disableOnDemand()` -> `vpnManager.disconnect()`
   - Waits 1 second
   - Reconnects with modified config: `vpnManager.connect(configJSON: updatedConfig)`

### 4. VPN Status Observation (`handleStatus()`)

Listens to `NEVPNStatusDidChange` notifications:

- **`.connected`**: Sets `vpnConnectedAt` timestamp, connects `commandClient` if not already
- **`.disconnected` / `.invalid`**: Clears `vpnConnectedAt`, disconnects `commandClient`
- Other states: ignored

---

## API Communication

### APIClient Architecture

Two `URLSession` instances:
- `session` -- standard session, 5s timeout
- `fallbackSession` -- with `InsecureDelegate` that trusts all certificates (for direct IP access), 5s timeout

### Fallback Chain (`dataWithFallback()`)

Every request attempts 3 URLs in sequence:

1. **Primary (Cloudflare)**: `https://razblokirator.ru` -- standard HTTPS, 5s timeout
2. **Russian Relay (SPB)**: `http://185.218.0.43` -- HTTP over insecure session, 7s timeout. Highest priority fallback for users in Russia
3. **Direct IP**: `http://162.19.242.30` -- HTTP over insecure session, 10s timeout. Last resort

URL replacement: replaces `AppConfig.baseURL` in the original URL with the fallback base URL, preserving the path.

### Endpoints Used by iOS App

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/mobile/auth/register` | Device registration (trial). Body: `{"device_id": "<UUID>"}` |
| `POST` | `/api/mobile/auth/activate` | Activate with code from Telegram bot. Body: `{"code": "<str>"}` |
| `POST` | `/api/mobile/auth/apple` | Apple Sign-In. Body: `{"identity_token": "<JWT>", "user_identifier": "<str>"}` |
| `POST` | `/api/mobile/auth/apple/activate` | Apple Sign-In + activation code. Body includes both |
| `POST` | `/api/mobile/auth/refresh` | Refresh access token. Body: `{"refresh_token": "<str>"}` |
| `GET` | `/api/v1/mobile/config` | Download sing-box config. Query: `username=X&mode=Y` |

**Note**: Routes are mounted at both `/api/v1/mobile` and `/api/mobile` (legacy path) in `chameleon-apple/src/lib.rs`.

### Auth Flow (Backend: `mobile/auth.rs`)

**Device Registration** (`POST /auth/register`):
1. Validates `device_id` not empty, max 256 chars
2. Checks if device already registered (`find_user_by_device_id`)
3. If existing + active: returns tokens for existing user
4. If new: creates user with `vpn_username = "device_<uuid8>"`, generates `vpn_uuid`, `vpn_short_id`, sets `subscription_expiry` to now + `TRIAL_DAYS` (default 7)
5. Adds user to Xray live via gRPC (`add_user_to_all_inbounds`)
6. Returns `{access_token, refresh_token, username, expires_at}`

**Apple Sign-In** (`POST /auth/apple`):
1. Validates `identity_token` not empty, max 4096 chars
2. Verifies Apple JWT: fetches Apple JWKS (cached 1h), validates RS256 signature, checks issuer (`https://appleid.apple.com`), audience (bundle_id), expiry
3. Extracts `sub` claim (Apple user ID)
4. Finds or creates user by `apple_id`
5. Returns tokens

**Token Refresh** (`POST /auth/refresh`):
1. Verifies refresh token using `mobile_jwt_secret`
2. Looks up user by ID from token `sub` claim
3. Issues new access + refresh tokens
4. **Note**: IP is extracted but NOT bound to token for mobile (LTE changes IPs)

### Config Download (`GET /config`)

Handler in `chameleon-apple/src/mobile/config.rs`:
1. Requires `username` query param
2. Looks up user in DB: `vpn_username`, `vpn_uuid`, `vpn_short_id`
3. Creates `ProtocolRegistry` from settings
4. Gets `ServerConfig[]` from `engine.build_server_configs()`
5. Calls `singbox::generate_config(registry, creds, servers)` -- returns JSON Value
6. Returns JSON directly (the iOS client receives it as a string via `fetchConfig()`)

**Client-side** (`APIClient.fetchConfig()`):
- Always uses `/api/v1/mobile/config` with `username` and `mode` query params
- Bearer token is NOT sent (the endpoint currently does not require auth -- see Known Issues)
- Reads `X-Expire` response header for subscription expiry
- Uses the fallback chain
- 30s timeout

---

## Config Generation

### sing-box Config (`singbox.rs: generate_config()`)

Produces a complete sing-box client configuration JSON. The flow:

1. **Outbound generation**: Iterates `registry.enabled()`, only processes `vless_reality` protocol. For each server, generates a VLESS Reality TCP outbound with tag `"{flag} {name}"` (e.g. "NL Нидерланды").

2. **Grouping outbounds**:
   - If >1 server: Creates `selector` outbound named "Proxy" containing all server tags + "Auto", defaults to "Auto". Creates `urltest` outbound named "Auto" with all server tags, URL `https://www.gstatic.com/generate_204`, interval `300s`.
   - If 1 server: Creates `selector` "Proxy" with just that one server as default.

3. **Hysteria2 hardcoded**: Adds a hardcoded Hysteria2 outbound:
   - Tag: `"Fast (Hysteria2)"`
   - Server: `162.19.242.30:8443`
   - Password: `ChameleonHy2-2026-Secure`
   - SNI: `ads.x5.ru`, insecure: true
   - **Problem**: These credentials are hardcoded, not from Settings

4. **Hysteria2 added to groups**: Inserted into selector (before "Auto") and appended to urltest outbounds array.

5. **Direct outbound**: `{"type": "direct", "tag": "direct"}`

6. **Full config structure**:

```json
{
  "log": {"level": "warning"},
  "dns": {
    "servers": [
      {"tag": "dns-remote", "address": "https://1.1.1.1/dns-query", "detour": "Auto"},
      {"tag": "dns-direct", "address": "https://8.8.8.8/dns-query", "detour": "direct"}
    ],
    "rules": [
      {"outbound": "direct", "server": "dns-direct"}
    ],
    "final": "dns-remote",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
     "auto_route": true, "stack": "system", "mtu": 1400}
  ],
  "outbounds": [...],
  "route": {
    "default_domain_resolver": {"server": "dns-direct", "strategy": "ipv4_only"},
    "rules": [
      {"action": "sniff"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"ip_is_private": true, "outbound": "direct"}
    ]
  }
}
```

### VLESS Reality Outbound (`vless_reality.rs: singbox_outbound()`)

Generates per-server outbound:

```json
{
  "type": "vless",
  "tag": "<server tag>",
  "server": "<host or domain>",
  "server_port": 2096,
  "uuid": "<user vpn_uuid>",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "<sni from REALITY_SNIS, default ads.x5.ru>",
    "utls": {"enabled": true, "fingerprint": "chrome"},
    "reality": {"enabled": true, "public_key": "<REALITY_PUBLIC_KEY>", "short_id": "<user short_id>"}
  }
}
```

- Default transport: TCP with `xtls-rprx-vision` flow
- Alternative: XHTTP transport (no flow, adds `{"type": "http", "method": "GET"}`)
- Port: from server config, falls back to `VLESS_TCP_PORT` (2096) or `VLESS_GRPC_PORT` (2098)

### Hysteria2 Outbound (`hysteria2.rs: singbox_outbound()`)

```json
{
  "type": "hysteria2",
  "tag": "<tag>",
  "server": "<server host IP>",
  "server_port": 8443,
  "password": "<HY2_PASSWORD>",
  "tls": {
    "enabled": true,
    "server_name": "<HY2_SNI>",
    "insecure": true,
    "certificate_sha256": "<if set>"
  },
  "obfs": {"type": "salamander", "password": "<HY2_OBFS_PASSWORD>"}
}
```

### Config Sanitization (`ConfigSanitizer.swift`)

**Currently a passthrough** -- `sanitizeForIOS()` returns the input unchanged. The disabled code (`_sanitizeForIOS_disabled`) would have done:

1. Set log level (info for DEBUG, warn for RELEASE) + file output
2. Remove `clash_api` from experimental (sandbox blocks TCP bind)
3. Set `strict_route = false` on TUN, remove deprecated `sniff`/`sniff_override_destination`
4. Add `udp_fragment = true` to direct outbound (sing-box 1.13+ isEmpty fix)
5. Remove `domain_strategy` from DNS servers
6. Remove `outbound: any` DNS rules
7. Ensure `route.default_domain_resolver` exists
8. Remove deprecated `dns.strategy`
9. Remove `auto_detect_interface` from route

The passthrough comment says "backend generates sing-box 1.13 compatible config" so sanitization was moved server-side.

### Config Storage (`ConfigStore.saveConfig()`)

1. Calls `ConfigSanitizer.sanitizeForIOS()` (currently passthrough)
2. Validates with `LibboxCheckConfig()` -- sing-box's built-in config validation
3. Creates `sing-box/` and `sing-box-tmp/` directories in App Group container
4. Writes sanitized config to `AppConstants.configFileURL`
5. Also saves to UserDefaults `startOptionsKey` for On-Demand reconnects
6. Updates `lastConfigUpdate` timestamp

---

## VPN Connection

### VPNManager (`VPNManager.swift`)

**`connect(configJSON:)`:**

1. If no existing `NETunnelProviderManager`:
   - Creates one with `NETunnelProviderProtocol`
   - `providerBundleIdentifier` = `"com.chameleonvpn.app.tunnel"`
   - `serverAddress` = `"Chameleon VPN"` (displayed in iOS Settings)
   - On Demand rules: `[NEOnDemandRuleConnect()]` but `isOnDemandEnabled = false`
   - `saveToPreferences()` triggers iOS VPN permission prompt
   - `loadFromPreferences()` to reload saved state

2. Ensures profile `isEnabled`

3. Enables On Demand (`isOnDemandEnabled = true`) so iOS auto-reconnects on network changes

4. Passes config as `startTunnel` option: `["configContent": configJSON]`

**`disconnect()`:**
1. Disables On Demand (prevents auto-reconnect after explicit disconnect)
2. Calls `stopVPNTunnel()`

**`resetProfile()`:**
1. Disconnects
2. Removes VPN profile from preferences
3. Resets local state

### PacketTunnel Extension (`ExtensionProvider.swift`)

**`startTunnel(options:completionHandler:)`:**

1. Clears `TunnelFileLogger`
2. Config loading priority:
   - **Tunnel options**: `options["configContent"]` (passed from VPNManager.connect)
   - **Persisted UserDefaults**: `startOptionsKey` (for On-Demand reconnects)
   - **Config file**: `AppConstants.configFileURL`
   - If none found: returns error
3. Sanitizes config via `ConfigSanitizer.sanitizeForIOS()` (passthrough)
4. Dispatches to background queue (MUST -- `startOrReloadService` blocks, and `setTunnelNetworkSettings` needs the provider queue free)
5. Calls `startSingBox(config:)`

**`startSingBox(config:)` -- sing-box Engine Setup:**

1. `LibboxSetupOptions`: sets base/working/temp paths, debug=true, logMaxLines=500
2. `LibboxSetup()` -- initializes libbox
3. `LibboxSetMemoryLimit(true)` -- constrains memory for extension process
4. `LibboxRedirectStderr()` -- redirects to `stderr.log` in App Group container
5. Creates `ExtensionPlatformInterface` -- bridges Go engine to iOS
6. Creates `LibboxCommandServer` -- with platform as both PlatformInterface and CommandServerHandler
7. `server.start()` -- starts gRPC listener on Unix socket at `command.sock`. **Non-fatal** if fails -- VPN works without live stats
8. `server.startOrReloadService(config, options:)` -- **BLOCKS** -- starts the sing-box service

**`stopTunnel()`:**
1. `server.closeService()` -- stops sing-box
2. `server.close()` -- closes gRPC listener
3. Resets state

**`handleAppMessage()`:**
- `"reload"`: Re-reads config file and calls `reloadService()`
- `"status"`: Returns JSON with `grpcAvailable` and `running` booleans
- `"diagnostics"`: Returns libbox version, engine/gRPC state, config file existence, log sizes

**`sleep()` / `wake()`:**
- Pauses/resumes the command server (battery saving)

### ExtensionPlatformInterface (`ExtensionPlatformInterface.swift`)

Implements `LibboxPlatformInterfaceProtocol` + `LibboxCommandServerHandlerProtocol`.

**Key methods:**

- **`openTun()`**: Called by sing-box Go to create TUN device. Uses `runBlocking()` to bridge async `setTunnelNetworkSettings()` call. Builds `NEPacketTunnelNetworkSettings`:
  - IPv4: `172.19.0.1/30`, default route included, APNs excluded (`17.0.0.0/8`)
  - IPv6: `fdfe:dcba:9876::1/126`, default route included
  - DNS: `1.1.1.1` (or from sing-box options), `matchDomains = [""]` (all DNS through tunnel)
  - Gets TUN fd from `packetFlow.fileDescriptor` or `LibboxGetTunnelFileDescriptor()`

- **`autoDetectControl()`**: Logs fd, returns (sing-box uses platform auto-detect for bind-to-interface)

- **`startDefaultInterfaceMonitor()`**: Creates `NWPathMonitor`, reports interface changes (WiFi/cellular transitions) to sing-box via `listener.updateDefaultInterface()`

- **`clearDNSCache()`**: Toggles `reasserting` flag to flush iOS DNS cache

- **`usePlatformAutoDetectControl()`**: Returns `true` -- lets sing-box bind outgoing sockets to the right interface

- **`writeDebugMessage()`**: Forwards sing-box debug messages to both `TunnelFileLogger` and `singbox.log` file

---

## DNS Resolution

### Config-Level DNS (from `singbox.rs`)

```json
{
  "dns": {
    "servers": [
      {"tag": "dns-remote", "address": "https://1.1.1.1/dns-query", "detour": "Auto"},
      {"tag": "dns-direct", "address": "https://8.8.8.8/dns-query", "detour": "direct"}
    ],
    "rules": [
      {"outbound": "direct", "server": "dns-direct"}
    ],
    "final": "dns-remote",
    "strategy": "ipv4_only"
  }
}
```

**Flow:**
1. All DNS queries are hijacked by sing-box (`"protocol": "dns", "action": "hijack-dns"` route rule)
2. DNS for traffic going through the `direct` outbound uses `dns-direct` (Google DoH via direct connection)
3. All other DNS uses `dns-remote` (Cloudflare DoH via the Auto/Proxy outbound) -- encrypted and proxied
4. Strategy: `ipv4_only` everywhere

**Route-Level DNS:**
- `default_domain_resolver`: `{"server": "dns-direct", "strategy": "ipv4_only"}` -- used to resolve server hostnames in outbound configs

### iOS Network Settings DNS

Set in `ExtensionPlatformInterface.buildTunnelSettings()`:
- DNS server: from sing-box options, defaults to `1.1.1.1`
- `matchDomains = [""]` -- routes ALL DNS queries through the tunnel

---

## Server Selection

### Data Model

```
ServerGroup
  - tag: String (e.g. "Proxy", "Auto")
  - type: "selector" | "urltest"
  - selected: String (currently active server tag)
  - items: [ServerItem]
  - selectable: Bool

ServerItem
  - tag: String (e.g. "NL Нидерланды", "Fast (Hysteria2)")
  - type: String (e.g. "vless", "hysteria2")
  - delay: Int32 (ping in ms, 0 if unknown)
  - countryKey: derived from tag ("nl", "de", "ru", "cdn", "other")

CountryGroup (computed from ServerGroup)
  - groups items by countryKey
  - hides CDN entries from UI
  - provides country name, flag, best delay, protocol subtitle
```

### How the UI Interacts

**Server list (`ServerListView`):**
1. Shows "Auto (best ping)" option at top
2. Lists all selectable groups with their items
3. Tapping a server calls `app.selectServer(groupTag:serverTag:)`

**How selector/urltest work in sing-box:**

The config has two outbound groups:
- `Proxy` (selector): manual pick -- user selects here. Default is "Auto"
- `Auto` (urltest): automatic best-ping selection among all server outbounds

The selector can point to either a specific server or to "Auto" (which then auto-selects).

**Runtime selection when VPN is connected:**

`AppState.selectServer()`:
1. Modifies the config JSON in memory -- changes the selector's `default` field
2. Stores in UserDefaults for On-Demand reconnects
3. Disconnects and reconnects VPN with the modified config
4. Does NOT use sing-box gRPC `selectOutbound()` -- instead does a full reconnect cycle

**CommandClient live data:**

The `CommandClientWrapper` connects to the extension's gRPC server via Unix socket. It receives:
- **Status updates**: upload/download speed and totals, connection counts (every 1s)
- **Group updates**: current outbound groups with items, selected servers, and ping delays

The `selectedServer` computed property:
1. Checks for a selector group that contains urltest items
2. Finds the selected urltest group, returns its auto-selected server
3. Falls back to the first urltest group's selected server

### Server Parsing from Config (`ConfigStore.parseServersFromConfig()`)

1. Reads config JSON from file
2. Indexes all outbounds by tag
3. For `urltest` outbounds: extracts member tags, maps to `ServerItem`s (only proxy types: vless, vmess, trojan, shadowsocks, hysteria, hysteria2, wireguard, tuic)
4. For `selector` outbounds: extracts member tags (includes non-proxy types like "Auto")
5. Applies saved `selectedServerTag` from UserDefaults
6. Fallback: if no groups found, creates synthetic "Proxy" selector from standalone proxy outbounds

---

## Shared Utilities

### KeychainHelper (`Shared/KeychainHelper.swift`)

Simple Keychain wrapper using `kSecClassGenericPassword`:
- Service: `"com.chameleonvpn.app"`
- Accessibility: `kSecAttrAccessibleAfterFirstUnlock` -- tunnel extension can read when device is locked
- Methods: `save(key:value:)`, `load(key:) -> String?`, `delete(key:)`

**Stored keys:**
- `"username"` -- vpn_username
- `"mobileAccessToken"` -- JWT access token
- `"mobileRefreshToken"` -- JWT refresh token

### TunnelFileLogger (`Shared/TunnelFileLogger.swift`)

File-based logger for the PacketTunnel extension (os.log not accessible from extensions):
- File: `tunnel-debug.log` in App Group container
- Max size: 512 KB -- auto-truncates (keeps last half)
- Format: `[HH:mm:ss.SSS] [category] message`
- Thread-safe via serial DispatchQueue
- Also provides access to `stderr.log` (redirected libbox stderr)

### RunBlocking (`Shared/RunBlocking.swift`)

Bridges async/await to synchronous Go callbacks:
- Creates `DispatchSemaphore`, dispatches `Task.detached`, waits on semaphore
- Used by `ExtensionPlatformInterface.openTun()` which is called from Go's synchronous context
- Two overloads: throwing and non-throwing

### ConfigSanitizer (`Shared/ConfigSanitizer.swift`)

**Currently disabled** -- `sanitizeForIOS()` is a passthrough returning the input unchanged.

The disabled implementation would fix 8 categories of sing-box config incompatibilities. It was disabled because the backend now generates sing-box 1.13 compatible configs directly.

### AppLogger (`Shared/Logger.swift`)

Three `os.log.Logger` instances:
- `AppLogger.app` -- main app logging
- `AppLogger.tunnel` -- tunnel extension logging
- `AppLogger.network` -- network-related logging
- Subsystem: `"com.chameleonvpn.app"`

---

## Data Models

### ServerItem (`ServerGroup.swift`)

Key computed properties:
- `countryKey`: detects country from tag text ("NL"/"NL"/"Нидерланды" -> "nl", etc.)
- `flagEmoji`: country flag
- `protocolLabel`: "VLESS", "HY2", "WG", or uppercased type
- `shortLabel`: extracts text from brackets, or detects gRPC/CDN/HY2
- `isHysteria`: checks tag for "hysteria"/"hy2" or type "hysteria2"
- `displayLabel`: e.g. "HY2 . Relay", "VLESS . TCP", "CDN . Cloudflare"
- `homePillLabel`: e.g. "NL . HY2 Direct", "DE . VLESS TCP"

### CountryGroup (`ServerGroup.swift`)

Groups servers by country for simplified display:
- Static `from(key:items:)` factory
- Computes `bestDelay` (minimum positive delay)
- `protocolSubtitle`: e.g. "5 VLESS + 1 HY2"
- `sortOrder`: NL=0, DE=1, RU=2, other=10
- CDN entries are filtered out in `ServerGroup.countryGroups`

---

## Known Issues

### 1. Hardcoded Hysteria2 Credentials in `singbox.rs`

**Location**: `backend/crates/chameleon-vpn/src/singbox.rs` lines 64-76

The Hysteria2 outbound is hardcoded with server IP, port, password, and SNI rather than being generated from `Settings` and the protocol registry. This means:
- Credentials in code, not in env vars
- The `Hysteria2` protocol's `singbox_outbound()` method is never called by `generate_config()`
- Only `vless_reality` protocol's `singbox_outbound()` is used in the loop (line 20: `if proto.name() != "vless_reality" { continue; }`)

### 2. Config Endpoint Has No Authentication

**Location**: `backend/crates/chameleon-apple/src/mobile/config.rs`

The `GET /config?username=X` endpoint does not verify any JWT token. Anyone who knows a username can download their full sing-box config including UUID and credentials. The iOS app does send an `accessToken` parameter to `fetchConfig()` but the method never adds it as a Bearer header.

### 3. ConfigSanitizer is Disabled (Passthrough)

**Location**: `apple/Shared/ConfigSanitizer.swift`

`sanitizeForIOS()` does nothing -- relies entirely on backend generating correct config. If the backend config ever has issues (clash_api, strict_route, etc.), the extension will fail without client-side fixes.

### 4. Server Selection Requires Full Reconnect

**Location**: `apple/ChameleonVPN/Models/AppState.swift` `selectServer()`

Changing servers disconnects and reconnects the VPN (1-second delay). The `CommandClient.selectOutbound()` method exists but is not used in the main selection flow. This causes a visible connection interruption for the user.

### 5. Only VLESS Reality TCP is Generated for sing-box Outbounds

**Location**: `backend/crates/chameleon-vpn/src/singbox.rs` line 20

The `generate_config()` function skips all protocols except `vless_reality`, and only generates TCP outbounds (using default `OutboundOpts`). XHTTP, gRPC, CDN, Hysteria2 (from registry), WARP, AnyTLS, NaiveProxy outbounds are never generated for the iOS config even though the protocols implement `singbox_outbound()`.

### 6. Access Token Not Sent With Config Request

**Location**: `apple/ChameleonVPN/Models/APIClient.swift` `fetchConfig()` line 176

The `accessToken` parameter is accepted but never used -- no `Authorization: Bearer` header is set on the request. The backend doesn't check it either (see issue 2).

### 7. `dns.strategy` and `dns.final` May Be Deprecated

**Location**: `backend/crates/chameleon-vpn/src/singbox.rs` DNS config

The generated config uses `"strategy": "ipv4_only"` at top-level DNS and `"final": "dns-remote"`. In sing-box 1.13+, `strategy` was moved to `default_domain_resolver` (which is set in the route section). The `final` field at DNS level may conflict with the route-level `default_domain_resolver`. However, the `ConfigSanitizer` that would have fixed this is disabled.

### 8. Keychain Not Shared With Extension

**Location**: `apple/Shared/KeychainHelper.swift`

The Keychain helper uses a hardcoded service `"com.chameleonvpn.app"` but does not set a Keychain access group. This means the PacketTunnel extension may not be able to access stored credentials. Currently this is not a problem because the extension reads config from the App Group file/UserDefaults, not from Keychain. But if auth tokens are ever needed in the extension, this will fail.

### 9. No Token Refresh Flow in iOS Client

**Location**: `apple/ChameleonVPN/Models/APIClient.swift`

The `refreshAccessToken()` method exists but is never called anywhere in the app. If the access token expires (default 15 minutes), there's no automatic refresh. Currently this doesn't matter because the config endpoint doesn't require auth, but it will break if auth is ever enforced.

### 10. On-Demand Config May Go Stale

When On-Demand reconnects the VPN, the extension reads from UserDefaults `startOptionsKey`. This is only updated when:
- Config is saved (`ConfigStore.saveConfig()`)
- Server is manually switched (`AppState.selectServer()`)

If the user's credentials change on the backend (e.g., account deactivated, UUID rotated), the On-Demand reconnect will use stale config.

### 11. `repairConfigIfNeeded()` Silently Deletes Config

If a config has no selector/urltest (e.g., a single-server config), it's deleted and re-fetched. This could cause issues if the backend legitimately returns a single-outbound config.

### 12. Missing Error Recovery for Registration

If `autoRegister()` fails (network error, server down), the user sees an error message but there's no retry mechanism. The user must relaunch the app.

### 13. UIDevice.current Not Available on macOS

**Location**: `apple/ChameleonVPN/Models/APIClient.swift` line 102

`UIDevice.current.identifierForVendor` is used for device registration. This won't compile for the macOS target without conditional compilation (`#if canImport(UIKit)` wrapping is at the import level but not around this specific usage).

### 14. DNS Potential Loop Risk

DNS servers use DoH (HTTPS), which itself requires DNS resolution. The config mitigates this with:
- `default_domain_resolver` pointing to `dns-direct` -- resolves server hostnames via direct connection
- `dns-direct` uses `https://8.8.8.8/dns-query` (IP-based DoH, no DNS needed to reach it)
- `dns-remote` uses `https://1.1.1.1/dns-query` (also IP-based)

This should work, but if the IP changes or the DoH server requires hostname resolution, a DNS loop could occur.
