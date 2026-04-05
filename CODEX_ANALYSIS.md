# Chameleon VPN Technical Audit

Date: 2026-04-05
Scope: 13 requested files reviewed line-by-line.

## 1. CODE-LEVEL BUG REPORT

### 1.1 `backend/crates/chameleon-vpn/src/singbox.rs`
- [CRITICAL] Mobile config generation is hard-filtered to `vless_reality` only (`19-20`). Registry protocols (`vless_cdn`, `hysteria2`, etc.) are excluded.
- [CRITICAL] Hardcoded HY2 endpoint/secret/SNI/TLS insecurity (`63-76`): `162.19.242.30:8443`, static password, fixed SNI, `insecure: true`.
- [CRITICAL] DNS dependency cycle: `dns-remote` detours through `Auto` (`101`), and DNS `final` is `dns-remote` (`107`). Under blocked paths, DNS stalls and all domain traffic stalls.
- [HIGH] Outbound mutation by index assumes selector=urltest positions (`77-93`), wrong for `tags.len()==0` or `1`.
- [HIGH] No multi-SNI/per-carrier outbound generation in mobile output (`23-24` uses default opts only).
- [HIGH] `dns-direct` fixed to DoH `8.8.8.8` (`102`), no system/local resolver fallback.
- [MEDIUM] Tag collisions possible from `"{flag} {name}"` format (`22`).
- [MEDIUM] Single urltest URL (`48`) and long interval (`49`) reduce adaptation speed.

### 1.2 `backend/crates/chameleon-vpn/src/protocols/vless_reality.rs`
- [CRITICAL] Inbound matrix mismatch: hardcoded `2097` and `xhttp` used where gRPC path is expected (`126-127`).
- [HIGH] `relay_servers_raw` loaded but unused (`18`, `32`) -> dead branch.
- [HIGH] `singbox_outbound` lacks robust gRPC/WS generation (`148-174`) for practical fallback diversification.
- [HIGH] Port selection can force wrong transport port (`153`).
- [MEDIUM] Reality `dest` pinned to first SNI (`23-25`, `43`) despite multi-SNI list.
- [MEDIUM] Static uTLS fingerprint `chrome` (`9`, `164`) across all users.

### 1.3 `backend/crates/chameleon-vpn/src/protocols/types.rs`
- [HIGH] `ServerConfig` is too flat (`9-16`), missing per-transport ports, per-carrier SNI pools, CDN aliases, health metadata.
- [MEDIUM] `effective_host()` always prefers domain (`68-70`) even when DNS is impaired.
- [MEDIUM] `OutboundOpts.network` is unused (`63`), indicating incomplete transport wiring.

### 1.4 `backend/crates/chameleon-vpn/src/protocols/mod.rs`
- [HIGH/architectural] Module exposes many protocols (`3-12`), but mobile output path only emits one protocol (`singbox.rs:19-20`).

### 1.5 `backend/crates/chameleon-vpn/src/engine.rs`
- [CRITICAL] Xray API inbound exposed on `0.0.0.0` (`207-208`).
- [HIGH] Private IPs routed to `BLOCK` (`86`, `120`) can break LAN/private services.
- [HIGH] DNS hardcoded to public resolvers only (`97`, `124`) without censorship-aware policy.
- [HIGH] `VPN_SERVERS` parse failures are silently swallowed (`134`, `unwrap_or_default`).
- [MEDIUM] `std::fs` writes in async paths (`53`, `57`, `155-157`) can stall runtime threads.
- [MEDIUM] Serialization `unwrap_or_default()` may write empty config (`57`, `156`).
- [LOW] Fixed sleep after reload (`166`) adds deterministic latency.

### 1.6 `backend/crates/chameleon-config/src/lib.rs`
- [CRITICAL] Security-critical secrets auto-randomize when env absent (`253-259`, `348-349`), invalidating sessions/tokens after restart.
- [HIGH] Validation incomplete (`358-389`): no strong checks for `REALITY_PUBLIC_KEY`, `VPN_SERVERS`, protocol prerequisites.
- [HIGH] Weak default concentration: single default SNI and static ports (`273`, `275-279`, `283`).
- [MEDIUM] `parse_csv_ints` silently drops malformed values (`25-29`).
- [MEDIUM] `dotenvy::dotenv()` always called (`243`) can cause hidden env precedence issues in production.
### 1.7 `apple/ChameleonVPN/Models/AppState.swift`
- [CRITICAL] Server switch forces disconnect + reconnect with fixed 1s sleep (`156-162`), causing avoidable downtime.
- [HIGH] No reentrancy guard in `toggleVPN()` (`99-132`), race risk on rapid taps.
- [HIGH] “Silent” config refresh can set visible error state (`88-94`).
- [HIGH] Selector update rewrites all selector groups (`174-177`), not only target group.
- [MEDIUM] Repair heuristic may delete valid minimal configs (`48-65`).

### 1.8 `apple/ChameleonVPN/Models/APIClient.swift`
- [CRITICAL] Trust-all TLS delegate for fallback session (`40-50`, `64`) enables MITM.
- [CRITICAL] Fallback endpoints are HTTP (from constants), exposing control-plane traffic.
- [HIGH] `fetchConfig(..., accessToken:)` ignores token parameter (`168`, `174-178`).
- [HIGH] URL fallback by string replacement is brittle (`77-90`).
- [MEDIUM] Some auth flows skip fallback strategy (`141-143`, `212`, `234`, `256`).

### 1.9 `apple/ChameleonVPN/Models/ConfigStore.swift`
- [HIGH] Parsing can produce duplicated/ambiguous groups (`165-221`) and UI inconsistency.
- [MEDIUM] Selector items include meta/non-proxy entries (`199-210`).
- [MEDIUM] `metaOutboundTypes` unused (`15-17`).

### 1.10 `apple/ChameleonVPN/Models/VPNManager.swift`
- [HIGH] `load()` takes first manager (`17-20`), not guaranteed app-owned tunnel profile.
- [HIGH] Hot path preference writes during connect (`30-41`, `44-47`) add latency.
- [MEDIUM] Disconnect path races async save (`67-71`).
- [MEDIUM] Observer cleanup only in reset path (`84-87`, `105-113`).

### 1.11 `apple/ChameleonVPN/Models/CommandClient.swift`
- [HIGH] Built-in delays (`68`, `101`) worsen perceived readiness.
- [MEDIUM] Mutable state touched from multiple queues/tasks (`64-123`, `217-295`), token checks reduce but do not eliminate race exposure.
- [MEDIUM] No robust auto-reconnect policy after disconnect callback (`226-234`).

### 1.12 `apple/PacketTunnel/ExtensionProvider.swift`
- [CRITICAL] Full config logged verbatim (`50-53`) including sensitive fields.
- [HIGH] Persisted start options can shadow fresher file config (`33-43`, `229-235`).
- [HIGH] Debug mode enabled in tunnel runtime (`139`).
- [MEDIUM] Blocking startup call (`189-191`) increases connect latency.
- [MEDIUM] Plaintext config persisted in shared defaults (`229-231`).

### 1.13 `apple/Shared/Constants.swift`
- [CRITICAL] Single hardcoded fallback IP (`13`) and relay IP (`16`) are trivial block targets.
- [CRITICAL] HTTP fallback URLs (`13`, `16`) are insecure for control-plane requests.
- [HIGH] Endpoint values are static in app binary (`8-39`), making rapid rotation difficult.

## 2. ARCHITECTURE FLAWS

### Why current architecture fails under Russian censorship
1. Mobile generator emits a narrow path (mostly Reality TCP + hardcoded HY2), despite multi-protocol codebase.
2. DNS plane depends on proxy plane (`dns-remote -> Auto`), so one blocked path causes global failures.
3. Single dominant SNI and tiny IP pool are easy to fingerprint/block.
4. CDN fallback exists in protocol modules but is not wired into generated mobile config.
5. Control-plane fallback in app is insecure and still highly centralized.

### Single points of failure
- DE endpoint concentration (IP/port).
- Hardcoded HY2 endpoint and static secret.
- One SNI pattern.
- One health-check URL.
- One relay/fallback IP in app constants.

### Missing redundancy
- No per-carrier SNI fanout in mobile output.
- No multi-region IP fanout in generated config.
- No robust protocol fallback chain (Reality + CDN WS + gRPC + emergency transport).
- No independent DNS strategy that survives blocked proxy paths.

## 3. DNS DEEP DIVE

### Current DNS path (exact chain)
1. `AppState.toggleVPN()` starts tunnel via `VPNManager.connect()`.
2. `ExtensionProvider.startTunnel()` loads config and calls `startOrReloadService()`.
3. iOS routes DNS through tunnel (`ExtensionPlatformInterface.swift:217-220`, `matchDomains=[""]`).
4. sing-box route hijacks DNS packets (`singbox.rs:125`).
5. DNS selection:
   - direct-only queries can use `dns-direct` (`105`).
   - all others go `final=dns-remote` (`107`) with detour `Auto` (`101`).
6. If `Auto` picks blocked endpoint, DNS timeouts repeat for each domain query.

### Why it behaves like an infinite retry loop
- DNS availability depends on already-working proxy route.
- In blocked conditions, proxy route is unavailable.
- iOS resolver retries; sing-box keeps trying blocked path; user perceives 30-60s hangs.
- No FakeIP fast answer path means each domain waits for network resolver success.

### Correct sing-box DNS approach
- Enable `fakeip` for fast responses.
- Split DNS:
  - RU/local/private -> direct resolver.
  - other domains -> fakeip/remote via resilient proxy chain.
- Keep `route.default_domain_resolver` on direct/local to avoid bootstrap deadlock.

### Reference DNS block (generator target)
```json
{
  "dns": {
    "independent_cache": true,
    "strategy": "prefer_ipv4",
    "fakeip": {
      "enabled": true,
      "inet4_range": "198.18.0.0/15",
      "inet6_range": "fc00::/18"
    },
    "servers": [
      {"tag": "dns-local", "address": "local", "detour": "direct"},
      {"tag": "dns-direct-ru", "address": "https://77.88.8.8/dns-query", "detour": "direct"},
      {"tag": "dns-remote", "address": "https://1.1.1.1/dns-query", "detour": "proxy-chain"},
      {"tag": "dns-fakeip", "address": "fakeip"}
    ],
    "rules": [
      {"domain_suffix": ["ru", "su", "xn--p1ai"], "server": "dns-direct-ru"},
      {"rule_set": ["geosite-ru"], "server": "dns-direct-ru"},
      {"outbound": "direct", "server": "dns-local"},
      {"server": "dns-fakeip"}
    ],
    "final": "dns-remote"
  }
}
```

## 4. CONNECTION TIMELINE

### Current (where seconds are lost)
1. Tap connect.
2. Profile create/save/load on first use (`VPNManager.swift:28-41`).
3. On-demand preference write in hot path (`44-47`).
4. Extension setup + blocking service start (`ExtensionProvider.swift:132-191`).
5. First domain DNS query enters blocked `dns-remote -> Auto` chain (`singbox.rs:101,107`) and stalls.
6. Command client adds UI-only fixed delays (`CommandClient.swift:68,101`).

### Target to reach <1s practical connect
- Pre-create/enable tunnel profile before first connect.
- Remove hot-path on-demand preference writes.
- Remove heavy config logging/debug in extension runtime.
- Implement FakeIP split DNS.
- Switch servers live via command API without reconnect.

## 5. PROTOCOL GAPS

- Missing in generated output (or effectively missing): VLESS WS CDN, robust VLESS gRPC, emergency TUIC/Shadowsocks.
- CDN fallback path exists in codebase but not emitted by `singbox.rs` generator.
- Carrier-specific multi-SNI exists partially but is not used in generated mobile outbounds.
- Multiplexing should not be relied on with `xtls-rprx-vision`; use parallel outbounds + health-tested group selection.
## 6. COMPLETE TARGET SING-BOX JSON (GENERATOR TEMPLATE)

```json
{
  "log": {"level": "warn", "timestamp": true},
  "dns": {
    "independent_cache": true,
    "strategy": "prefer_ipv4",
    "fakeip": {"enabled": true, "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18"},
    "servers": [
      {"tag": "dns-local", "address": "local", "detour": "direct"},
      {"tag": "dns-direct-ru", "address": "https://77.88.8.8/dns-query", "detour": "direct"},
      {"tag": "dns-remote", "address": "https://1.1.1.1/dns-query", "detour": "proxy-chain"},
      {"tag": "dns-fakeip", "address": "fakeip"}
    ],
    "rules": [
      {"domain_suffix": ["ru", "su", "xn--p1ai"], "server": "dns-direct-ru"},
      {"rule_set": ["geosite-ru"], "server": "dns-direct-ru"},
      {"outbound": "direct", "server": "dns-local"},
      {"server": "dns-fakeip"}
    ],
    "final": "dns-remote"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true,
      "strict_route": false,
      "stack": "system",
      "mtu": 1400
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "reality-de-1-eh",
      "server": "__DE_IP_1__",
      "server_port": 443,
      "uuid": "__UUID__",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "__SNI_EH__",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {"enabled": true, "public_key": "__REALITY_PUBLIC_KEY__", "short_id": "__SHORT_ID__"}
      }
    },
    {
      "type": "vless",
      "tag": "reality-de-1-megafon",
      "server": "__DE_IP_1__",
      "server_port": 443,
      "uuid": "__UUID__",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "__SNI_MEGAFON__",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {"enabled": true, "public_key": "__REALITY_PUBLIC_KEY__", "short_id": "__SHORT_ID__"}
      }
    },
    {
      "type": "vless",
      "tag": "reality-nl-1-event",
      "server": "__NL_IP_1__",
      "server_port": 443,
      "uuid": "__UUID__",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "__SNI_EVENT__",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {"enabled": true, "public_key": "__REALITY_PUBLIC_KEY__", "short_id": "__SHORT_ID__"}
      }
    },
    {
      "type": "vless",
      "tag": "cdn-ws-1",
      "server": "__CDN_DOMAIN_1__",
      "server_port": 443,
      "uuid": "__UUID__",
      "tls": {"enabled": true, "server_name": "__CDN_DOMAIN_1__", "utls": {"enabled": true, "fingerprint": "chrome"}},
      "transport": {"type": "ws", "path": "/vless-ws", "headers": {"Host": "__CDN_DOMAIN_1__"}}
    },
    {
      "type": "vless",
      "tag": "cdn-grpc-1",
      "server": "__CDN_DOMAIN_2__",
      "server_port": 443,
      "uuid": "__UUID__",
      "tls": {"enabled": true, "server_name": "__CDN_DOMAIN_2__", "utls": {"enabled": true, "fingerprint": "chrome"}},
      "transport": {"type": "grpc", "service_name": "grpc"}
    },
    {
      "type": "hysteria2",
      "tag": "hy2-de-1",
      "server": "__HY2_IP_1__",
      "server_port": 443,
      "password": "__HY2_PASSWORD__",
      "tls": {"enabled": true, "server_name": "__HY2_SNI__", "insecure": false},
      "obfs": {"type": "salamander", "password": "__HY2_OBFS_PASSWORD__"}
    },
    {
      "type": "urltest",
      "tag": "auto-reality",
      "outbounds": ["reality-de-1-eh", "reality-de-1-megafon", "reality-nl-1-event"],
      "url": "https://cp.cloudflare.com/generate_204",
      "interval": "20s",
      "tolerance": 30
    },
    {
      "type": "urltest",
      "tag": "auto-cdn",
      "outbounds": ["cdn-ws-1", "cdn-grpc-1"],
      "url": "https://cp.cloudflare.com/generate_204",
      "interval": "20s",
      "tolerance": 30
    },
    {
      "type": "urltest",
      "tag": "auto-hy2",
      "outbounds": ["hy2-de-1"],
      "url": "https://cp.cloudflare.com/generate_204",
      "interval": "20s",
      "tolerance": 50
    },
    {
      "type": "urltest",
      "tag": "auto-all",
      "outbounds": ["auto-reality", "auto-cdn", "auto-hy2"],
      "url": "https://cp.cloudflare.com/generate_204",
      "interval": "15s",
      "tolerance": 20
    },
    {
      "type": "selector",
      "tag": "proxy-chain",
      "outbounds": ["auto-all", "auto-reality", "auto-cdn", "auto-hy2"],
      "default": "auto-all",
      "interrupt_exist_connections": true
    },
    {
      "type": "selector",
      "tag": "Proxy",
      "outbounds": ["proxy-chain", "auto-all", "auto-reality", "auto-cdn", "auto-hy2", "direct"],
      "default": "proxy-chain",
      "interrupt_exist_connections": true
    },
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ],
  "route": {
    "default_domain_resolver": {"server": "dns-local", "strategy": "prefer_ipv4"},
    "rule_set": [
      {
        "tag": "geosite-ru",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-ru.srs",
        "download_detour": "direct"
      },
      {
        "tag": "geoip-ru",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
        "download_detour": "direct"
      }
    ],
    "rules": [
      {"action": "sniff"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"ip_is_private": true, "outbound": "direct"},
      {"domain_suffix": ["ru", "su", "xn--p1ai"], "outbound": "direct"},
      {"rule_set": ["geosite-ru", "geoip-ru"], "outbound": "direct"}
    ],
    "final": "Proxy"
  }
}
```
## 7. IMPLEMENTATION ROADMAP

### Priority order + effort
1. **P0 (same day, 6-10h):**
   - Fix `singbox.rs` generator (remove hardcoded HY2, include CDN/hy2/reality variants, add FakeIP split DNS).
   - Remove insecure iOS fallback model (`APIClient.swift`, `Constants.swift`).
   - Remove config plaintext/full logging and debug runtime defaults (`ExtensionProvider.swift`).
2. **P1 (1-3 days):**
   - Expand server schema (`types.rs`, `engine.rs`, `chameleon-config/lib.rs`) for transport/SNI/CDN fanout.
   - Add robust gRPC/WS outbound generation in `vless_reality.rs`.
   - Switch server change to live command selection in app (`AppState.swift`).
3. **P2 (1 week):**
   - Add emergency transport (TUIC or Shadowsocks).
   - Add per-carrier SNI strategy + health telemetry feedback loop.

### Required code changes by file (with snippets)

#### `backend/crates/chameleon-vpn/src/singbox.rs`
```rust
for proto in registry.enabled() {
    for srv in servers {
        for opts in build_outbound_variants(proto.name(), srv, user) {
            let tag = format_tag(srv, &opts);
            if let Some(ob) = proto.singbox_outbound(&tag, srv, user, &opts) {
                outbounds.push(ob);
            }
        }
    }
}
```

#### `backend/crates/chameleon-vpn/src/protocols/vless_reality.rs`
```rust
match transport {
    "tcp" => out["flow"] = json!("xtls-rprx-vision"),
    "grpc" => out["transport"] = json!({"type": "grpc", "service_name": "grpc"}),
    "ws" => out["transport"] = json!({"type": "ws", "path": "/vless-ws", "headers": {"Host": sni}}),
    _ => {}
}
```

#### `backend/crates/chameleon-vpn/src/protocols/types.rs`
```rust
pub struct ServerConfig {
    pub host: String,
    pub domain: String,
    pub ports: std::collections::HashMap<String, u16>,
    pub snis: Vec<String>,
    pub cdn_domains: Vec<String>,
    pub flag: String,
    pub name: String,
    pub key: String,
}
```

#### `backend/crates/chameleon-vpn/src/engine.rs`
```rust
fn stats_api_inbound(port: u16) -> serde_json::Value {
    json!({"tag": "api", "listen": "127.0.0.1", "port": port, "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}})
}
```

#### `backend/crates/chameleon-config/src/lib.rs`
```rust
if self.reality_public_key.is_empty() {
    errors.push("REALITY_PUBLIC_KEY is required".into());
}
if self.vpn_servers_raw.is_empty() {
    errors.push("VPN_SERVERS is required".into());
}
```

#### `apple/ChameleonVPN/Models/AppState.swift`
```swift
guard !vpnManager.isProcessing else { return }
commandClient.selectOutbound(groupTag: groupTag, outboundTag: serverTag)
```

#### `apple/ChameleonVPN/Models/APIClient.swift`
```swift
if let token = accessToken, !token.isEmpty {
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
}
```

#### `apple/PacketTunnel/ExtensionProvider.swift`
```swift
TunnelFileLogger.log("Config loaded, bytes=\(configJSON.utf8.count)")
```

### Per-file change matrix (all 13 requested files)

1. `backend/crates/chameleon-vpn/src/singbox.rs`
- Remove protocol hard-filter; build outbounds from full registry.
- Remove hardcoded HY2 block and read HY2 outbounds from protocol implementation.
- Replace DNS with FakeIP split model and resilient `proxy-chain` detour.

2. `backend/crates/chameleon-vpn/src/protocols/vless_reality.rs`
- Fix inbound transport mapping (`grpc` should be real `grpc`).
- Add WS/gRPC outbound constructors for mobile generator.
- Use transport-specific ports from server metadata instead of `server.port` fallback for all modes.

3. `backend/crates/chameleon-vpn/src/protocols/types.rs`
- Extend `ServerConfig` with `ports`, `snis`, and `cdn_domains`.
- Extend `OutboundOpts` with `service_name`, `path`, `carrier`.

4. `backend/crates/chameleon-vpn/src/protocols/mod.rs`
- Keep module exports; add regression tests that fail if mobile generator emits only one protocol class.

5. `backend/crates/chameleon-vpn/src/engine.rs`
- Bind stats API to `127.0.0.1`.
- Replace silent JSON parse fallback with logged hard failure.
- Stop blocking file writes in async path (`tokio::fs` + atomic write).

6. `backend/crates/chameleon-config/src/lib.rs`
- Validate `REALITY_PUBLIC_KEY`, `VPN_SERVERS`, and censorship-resilience minima (SNI count, server pool size).
- Avoid random secret defaults in production.

7. `apple/ChameleonVPN/Models/AppState.swift`
- Replace reconnect-based server switch with `commandClient.selectOutbound(...)`.
- Guard connect/disconnect actions with `isProcessing`.

8. `apple/ChameleonVPN/Models/APIClient.swift`
- Drop trust-all delegate.
- Enforce HTTPS-only fallback endpoints.
- Actually set `Authorization` in config request when token exists.

9. `apple/ChameleonVPN/Models/ConfigStore.swift`
- Exclude meta outbounds from selectable server list.
- Build one canonical UI group model (avoid duplicate selector/urltest presentation).

10. `apple/ChameleonVPN/Models/VPNManager.swift`
- Select manager by `providerBundleIdentifier`, not first array item.
- Move on-demand preference writes out of hot connect path.

11. `apple/ChameleonVPN/Models/CommandClient.swift`
- Remove fixed startup sleeps; retry with short jittered backoff.
- Isolate mutable state on main actor or serial queue.

12. `apple/PacketTunnel/ExtensionProvider.swift`
- Stop logging full config.
- Change config precedence to prevent stale persisted options from shadowing fresh file/options.
- Set production `LibboxSetupOptions.debug = false`.

13. `apple/Shared/Constants.swift`
- Remove hardcoded fallback IPs; fetch signed endpoint manifest from backend.
- Replace HTTP fallback URLs with HTTPS-only endpoints.

## 8. iOS APP ISSUES

### AppState.swift
- Reconnect-based server selection (`156-162`) is the major user-visible latency/regression source.
- Missing rapid-tap guards (`99-132`) can trigger unstable state transitions.

### APIClient.swift
- Trust-all TLS and HTTP fallback are high-risk and should be removed first.
- Config endpoint auth parameter is currently not used.

### VPNManager.swift
- First-manager selection and preference writes in hot path add fragility and latency.

### PacketTunnel extension
- Sensitive config logging + stale config precedence create both security and reliability issues.

## Final Diagnosis

Your field symptoms (10-30s connects, DNS timeout loops, slow page load, speedtest failure) are fully explainable by the current code:
- narrow generated protocol set,
- DNS coupled to blocked proxy routes,
- missing real fallback diversity in emitted mobile config,
- insecure iOS fallback implementation that still doesn’t provide robust redundancy.

Immediate stabilization sequence:
1. Fix `singbox.rs` generation + FakeIP split DNS.
2. Remove insecure iOS fallback transport model.
3. Ship multi-SNI + CDN transport fanout in generated configs.
