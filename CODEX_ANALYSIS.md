# Chameleon VPN Technical Audit

Date: 2026-04-05
Scope: deep audit of 13 requested files.

---

## 1. CODE-LEVEL BUG REPORT

### 1.1 `backend/crates/chameleon-vpn/src/singbox.rs`

- **[CRITICAL] Only `vless_reality` is generated, other protocol plugins are ignored** (`19-29`).
  - `generate_config()` filters `proto.name() != "vless_reality"`, so `vless_cdn`, `hysteria2`, `warp`, `anytls`, `naiveproxy`, etc. in the registry never participate in mobile config generation.
  - Impact: architecture claims multi-protocol but runtime config is effectively single-protocol (+ one hardcoded HY2 entry).

- **[CRITICAL] Hardcoded HY2 endpoint and secret in client config generator** (`63-76`).
  - Fixed IP (`162.19.242.30`), fixed port (`8443`), fixed password (`ChameleonHy2-2026-Secure`), fixed SNI (`ads.x5.ru`), and `insecure: true` are hardcoded.
  - Impact: single censorship target, secret exposure in source, zero environment-driven rotation, TLS verification bypass.

- **[CRITICAL] DNS remote resolver detours through `Auto` proxy group** (`101`, `107`).
  - `dns-remote` uses detour `Auto`, and `final` is `dns-remote`.
  - If `Auto` picks blocked DE TCP:2096 or blocked UDP:8443 HY2 path, DNS stalls and all domain traffic stalls with it.

- **[CRITICAL] DNS bootstrap loop / dependency cycle** (`101-107`, `121-126`).
  - DNS for user traffic depends on proxy connectivity (`Auto`), proxy connectivity itself needs DNS for many targets, and route hijacks DNS (`hijack-dns`), creating repeated timeout chains.

- **[HIGH] Fragile outbound mutation by positional index assumptions** (`77-93`).
  - Code assumes `all_outbounds[0]` is selector and `all_outbounds[1]` is urltest.
  - For `tags.len()==1` there is no urltest, and for `tags.len()==0` `all_outbounds[0]` is HY2 outbound.
  - Impact: inconsistent group membership and hidden behavior drift when server count changes.

- **[HIGH] No generation of multi-SNI/per-carrier outbound variants** (`21-24`).
  - `OutboundOpts::default()` is always used (TCP + default SNI), while protocol code supports SNI override.
  - Impact: censorship adaptation unavailable in actual generated mobile config.

- **[HIGH] `dns-direct` uses DoH to `8.8.8.8` over direct path** (`102`).
  - In hostile networks this can be throttled/blocked; there is no local/system resolver fallback.

- **[MEDIUM] Server tags may collide** (`22`).
  - Tag uses `"{flag} {name}"`; duplicate country/name combinations produce non-unique tags and unstable selector behavior.

- **[MEDIUM] Urltest target may be blocked/slow** (`48`).
  - Single probe URL `https://www.gstatic.com/generate_204` is a weak health oracle for RU carrier conditions.

- **[LOW] Fixed URL test interval is too long for hostile networks** (`49`).
  - `300s` delays adaptation after a path is blocked.

### 1.2 `backend/crates/chameleon-vpn/src/protocols/vless_reality.rs`

- **[CRITICAL] XHTTP/GRPC inbound mismatch and hardcoded port** (`126-127`).
  - `"VLESS XHTTP REALITY"` uses hardcoded port `2097`, and `"VLESS XHTTP H2 REALITY"` also uses network `xhttp` (not `grpc`) on `grpc_port`.
  - Impact: transport matrix is inconsistent; expected gRPC path is not actually produced as gRPC.

- **[HIGH] `relay_servers_raw` is loaded but unused** (`18`, `32`).
  - Indicates partially implemented relay architecture; no runtime effect.

- **[HIGH] No ws/grpc transport generation for sing-box outbounds** (`148-174`).
  - Only `tcp` and pseudo-`xhttp` path are implemented.
  - Impact: missing CDN-friendly transports in mobile config.

- **[HIGH] Transport-specific port choice is weak** (`153`).
  - If `server.port != 0`, that port overrides all transports, potentially forcing xhttp/grpc onto tcp-only port.

- **[MEDIUM] `dest` uses first SNI only** (`23-25`, `43-45`).
  - Multiple SNI list is advertised in `serverNames`, but `dest` is pinned to first entry.
  - Impact: reduced realism/diversity and possible fingerprinting.

- **[MEDIUM] Single static fingerprint** (`9`, `164`).
  - Fixed `chrome` fingerprint across all users/servers.
  - Impact: easier traffic profiling.

- **[LOW] `xhttp` outbound payload likely too minimal** (`171-173`).
  - Only method is set; path/host/service fields are absent.

### 1.3 `backend/crates/chameleon-vpn/src/protocols/types.rs`

- **[HIGH] `ServerConfig` is too flat for censorship-era routing** (`9-16`).
  - Single `host/port/domain` cannot represent per-transport ports, per-carrier SNI pools, CDN aliases, health metadata.

- **[MEDIUM] `effective_host()` always prefers domain over IP** (`68-70`).
  - No policy to force IP during DNS impairment, despite host IP being present.

- **[MEDIUM] `OutboundOpts.network` is unused dead field** (`63`).
  - Signals incomplete transport control path.

- **[LOW] `remark()` blindly appends suffix with fixed spacing** (`78-79`).

### 1.4 `backend/crates/chameleon-vpn/src/protocols/mod.rs`

- **[HIGH, architectural wiring mismatch] Protocol modules are exposed (`3-12`) but mobile config path hard-filters to one protocol in `singbox.rs` (`19-20`).**
  - Not a syntax bug here, but this module layout masks functional under-utilization.

### 1.5 `backend/crates/chameleon-vpn/src/engine.rs`

- **[CRITICAL] Xray API inbound listens on `0.0.0.0`** (`207-208`).
  - Stats/handler API is network-exposed unless external firewall blocks it.

- **[HIGH] Private IP traffic is routed to `BLOCK`** (`86`, `120`).
  - `geoip:private -> BLOCK` breaks local/LAN/private services and some control-plane connectivity.

- **[HIGH] DNS config for xray control plane is static/global only** (`97`, `124`).
  - Hardcoded `1.1.1.1`, `8.8.8.8`; no country-aware resolver strategy.

- **[HIGH] Silent parse failure of `VPN_SERVERS`** (`134`).
  - `serde_json::from_str(...).unwrap_or_default()` converts parse errors into empty server list with no diagnostics.

- **[MEDIUM] Blocking FS writes in async functions** (`53`, `57`, `155-157`).
  - `std::fs::*` used inside async methods may stall executor threads.

- **[MEDIUM] Serialization fallback can write empty config** (`57`, `156`).
  - `to_string_pretty(...).unwrap_or_default()` can produce empty file on serialization error.

- **[MEDIUM] Added fixed 1s sleep after reload** (`166`).
  - Deterministic startup latency tax.

- **[LOW] `XRAY_CONFIG_DIR.is_dir()` gate can skip config generation unexpectedly** (`51-61`).

### 1.6 `backend/crates/chameleon-config/src/lib.rs`

- **[CRITICAL] Security-critical secrets auto-randomize on missing env** (`253-259`, `348-349`).
  - Session/JWT/cluster secrets silently rotate on restart if env is missing.
  - Impact: token invalidation, cluster partitioning, hard-to-debug auth churn.

- **[HIGH] Default SNI/ports are weak against censorship concentration** (`273`, `275-279`, `283`).
  - Single default Reality SNI and static default ports.

- **[HIGH] Validation is incomplete** (`358-389`).
  - Validates `REALITY_PRIVATE_KEY` but not `REALITY_PUBLIC_KEY`, not `VPN_SERVERS`, not protocol credentials needed for enabled protocols.

- **[MEDIUM] `parse_csv_ints()` silently drops malformed values** (`25-29`).
  - Can corrupt config intent without warning.

- **[MEDIUM] `dotenvy::dotenv()` always called in load path** (`243`).
  - Hidden env precedence side-effects in non-dev environments.

- **[LOW] `xray_version` default appears non-standard** (`335`).

### 1.7 `apple/ChameleonVPN/Models/AppState.swift`

- **[CRITICAL] Server switching forces full reconnect with hardcoded downtime** (`156-162`).
  - Disconnect + sleep(1s) + reconnect rather than in-place outbound switch.
  - Impact: avoidable 1s+ interruption and extra tunnel churn.

- **[HIGH] `toggleVPN()` lacks re-entrancy guard** (`99-132`).
  - No early return when `vpnManager.isProcessing`; rapid taps can trigger racey connect/disconnect sequences.

- **[HIGH] “Silent” config update surfaces user-visible error state** (`88-94`).
  - Any transient fetch failure can set `errorMessage`, degrading UX stability.

- **[HIGH] Selector rewrite modifies all selector outbounds indiscriminately** (`174-177`).
  - If config includes multiple selector groups, all defaults are overwritten.

- **[MEDIUM] Corruption heuristic can delete potentially valid minimal configs** (`48-65`).
  - Assumes selector/urltest must exist.

- **[MEDIUM] Status observer lifecycle not explicitly removed** (`18`, `190-197`).

### 1.8 `apple/ChameleonVPN/Models/APIClient.swift`

- **[CRITICAL] TLS trust-all fallback session enables MITM** (`40-50`, `64`, `82`, `94`).
  - Entire cert chain is bypassed for relay/IP fallbacks.

- **[CRITICAL] Fallback URLs use plain HTTP** (via constants used in `77-94`).
  - Token-bearing requests can traverse unencrypted channels.

- **[HIGH] `accessToken` argument is ignored in `fetchConfig()`** (`168`, `174-178`).
  - Comment says Bearer supported, implementation never sets `Authorization`.

- **[HIGH] Fallback URL rewriting is string-based** (`77-90`).
  - Fragile and can produce invalid endpoints or accidental path mutation.

- **[MEDIUM] No fallback path for several auth APIs** (`141-143`, `212`, `234`, `256`).
  - `activateCode`, Apple auth, and refresh use primary session only.

- **[LOW] Tight request timeouts + sequential fallback magnify cold-start latency** (`59`, `63`, `81`, `93`).

### 1.9 `apple/ChameleonVPN/Models/ConfigStore.swift`

- **[HIGH] Config parser builds duplicate/ambiguous group view** (`165-221`).
  - It adds both urltest and selector groups directly, which can mismatch intended UX model.

- **[MEDIUM] `metaOutboundTypes` is dead code** (`15-17`).

- **[MEDIUM] Selector group includes non-proxy members (e.g., `Auto`) as selectable server items** (`199-210`).

- **[LOW] `clear()` redundantly deletes username twice** (`130`, `134`).

### 1.10 `apple/ChameleonVPN/Models/VPNManager.swift`

- **[HIGH] `load()` picks first saved tunnel manager, not guaranteed app-owned profile** (`17-20`).

- **[HIGH] On-demand preferences are toggled during connect path** (`44-47`).
  - Preference writes add startup latency and can fail silently (`try?`).

- **[MEDIUM] `disconnect()` performs async preference save without waiting** (`67-71`).
  - Race between on-demand state save and tunnel stop.

- **[MEDIUM] Observer lifecycle cleanup only in `resetProfile()`** (`84-87`, `105-113`).

- **[LOW] `sendMessage()` has no timeout guard** (`92-103`).

### 1.11 `apple/ChameleonVPN/Models/CommandClient.swift`

- **[HIGH] Built-in connect delays inflate perceived readiness** (`68`, `101`).
  - Fixed 0.5s delay + 2s retry delay before marking stats unavailable.

- **[MEDIUM] Class is not isolated to MainActor; mutable shared state touched across task/main queues** (`11-38`, `64-123`, `217-295`).
  - Token checks reduce stale updates but do not fully eliminate data races.

- **[MEDIUM] No automatic re-connect after post-connect disconnect event** (`226-234`).

- **[LOW] Group interpretation logic assumes specific topology** (`191-204`).

### 1.12 `apple/PacketTunnel/ExtensionProvider.swift`

- **[CRITICAL] Full VPN config (credentials included) logged to file** (`50-53`).
  - Sensitive material at rest in app group container.

- **[HIGH] Persisted start config has highest precedence over file config** (`33-43`, `229-235`).
  - Stale persisted config can shadow fresher downloaded file indefinitely.

- **[HIGH] Debug mode enabled in production tunnel runtime** (`139`).
  - Higher overhead + verbose logs in security-sensitive process.

- **[MEDIUM] `startOrReloadService` is synchronous/blocking call in startup path** (`189-191`).
  - Contributes directly to long connect times.

- **[MEDIUM] Shared defaults store config plaintext** (`229-231`).

- **[LOW] Completion callback is invoked from background queue** (`60-71`).

### 1.13 `apple/Shared/Constants.swift`

- **[CRITICAL] Hardcoded single fallback IP + single relay IP** (`13`, `16`).
  - Trivial blocking target set.

- **[CRITICAL] HTTP fallback/relay endpoints** (`13`, `16`).
  - No TLS for fallback control-plane traffic.

- **[HIGH] Static deployment values in source** (`8-39`).
  - Requires app release for endpoint rotation.

---

## 2. ARCHITECTURE FLAWS

### Why current architecture fails under Russian censorship

1. **Single-path dependency graph**
   - Data plane is mostly Reality TCP + one hardcoded HY2 path.
   - Control plane (mobile config + DNS) also leans on same small endpoint set.
   - When DE IP/ports are filtered, both DNS and traffic stall.

2. **No carrier-specific adaptation**
   - Despite code hints for multiple SNIs (`vless_reality.rs:23, 89-96`), generated mobile config does not fan out per-carrier SNI variants.
   - One dominant SNI (`ads.x5.ru`) is fingerprintable and blockable.

3. **No real CDN fallback in generated config**
   - `vless_cdn` exists in protocol registry, but `singbox.rs` excludes it.
   - In practice users do not receive Cloudflare/WS/gRPC backup path from mobile endpoint.

4. **DNS and tunnel bootstrap are coupled to blocked upstream paths**
   - `dns-remote` detours through `Auto` which can choose blocked transport.
   - This converts route failure into universal app failure.

### Single points of failure

- Single DE IP for major paths (`162.19.242.30` hardcoded in app/client config).
- Single HY2 UDP port (`8443`) and single Reality TCP port (`2096` default).
- Single SNI default.
- Single health URL (`gstatic`) for urltest.
- Single fallback relay IP in app constants.

### Missing redundancy

- No multi-region IP pool selection in mobile config.
- No per-carrier SNI pool routing.
- No dual-stack transport matrix in generated config (Reality + CDN WS + gRPC + TUIC/SS fallback).
- No weighted failover policy with short health intervals.
- No independent DNS plane that survives proxy-plane outages.

---

## 3. DNS DEEP DIVE

### Current DNS resolution path (exact runtime flow)

1. User presses connect in app (`AppState.toggleVPN`, `99-132`), app passes config string into `VPNManager.connect()` (`51-56`).
2. Packet tunnel starts; extension loads config from options / persisted defaults / file (`ExtensionProvider.startTunnel`, `31-43`).
3. `startOrReloadService` starts sing-box (`189-191`).
4. During TUN setup, iOS DNS is forced through tunnel (`ExtensionPlatformInterface.buildTunnelSettings`, `217-220`, `matchDomains=[""]`).
5. sing-box inbound route has `{"protocol":"dns","action":"hijack-dns"}` (`singbox.rs`, `125`), so all DNS queries are intercepted.
6. DNS policy:
   - servers:
     - `dns-remote`: `https://1.1.1.1/dns-query`, detour=`Auto` (`101`)
     - `dns-direct`: `https://8.8.8.8/dns-query`, detour=`direct` (`102`)
   - rules: only outbound=`direct` -> `dns-direct` (`105`)
   - final: `dns-remote` (`107`)
7. For typical proxied app traffic, query does **not** match outbound=`direct`, so it goes to `dns-remote` via `Auto`.
8. `Auto` may resolve to blocked DE Reality or blocked HY2 path; DNS waits until transport timeout.
9. iOS resolver retries; each retry re-enters same chain, producing perceived “infinite retry / DNS death loop”.

### Why this creates retry loops and 30-60s stalls

- DNS success depends on tunnel success (`dns-remote -> Auto`).
- Tunnel success for many targets depends on DNS and initial connect path health.
- In blocked environments, repeated connect timeouts accumulate per query.
- No FakeIP fast response path exists, so every domain waits on remote DoH path availability.

### Correct DNS strategy (with FakeIP + split DNS)

Design goals:

- **Immediate DNS answers** for proxied domains: FakeIP.
- **Bypass tunnel dependency** for Russian/local domains: direct resolver path.
- **No circular dependency** between remote DNS and blocked proxy path.

Proposed logic:

1. Enable `dns.fakeip` ranges.
2. Add local/direct DNS servers (`local`, regional DoH/DoT reachable directly).
3. Add remote DNS server detoured via resilient proxy group (`proxy-chain`).
4. DNS rules:
   - `.ru`, `.su`, `xn--p1ai`, and RU geosite -> `dns-direct-ru`.
   - LAN/private reverse and local domains -> `dns-local`.
   - All remaining domains -> `dns-fakeip`.
5. Route rules:
   - RU domains/IPs -> `direct`.
   - All other traffic -> `Proxy`.

### Split DNS implementation detail

- Use suffix + rule-set matching, not only suffix:
  - suffix catches obvious TLDs.
  - rule-set catches RU services hosted under non-`.ru` domains.
- Keep `route.default_domain_resolver` on direct/local resolver so outbound server names can resolve even if proxy path is down.

---

## 4. CONNECTION TIMELINE

### Current timeline (best-effort based on code path)

1. **T+0ms**: user taps VPN button (`AppState.toggleVPN`).
2. **T+50-1500ms**: `VPNManager.connect()` may create profile, save/load preferences (`28-41`).
3. **T+200-800ms**: optional on-demand preference write (`44-47`).
4. **T+0.2-1.0s**: extension `startTunnel()` loads config + logs full JSON (`31-53`).
5. **T+0.3-1.5s**: `startSingBox()` setup + command server init (`132-178`).
6. **T+0.3-1.5s**: blocking `startOrReloadService()` and `setTunnelNetworkSettings` path (`189-191`, Platform `58-69`).
7. **T+1-30s+**: first domain query goes through `dns-remote` via `Auto`; blocked path causes timeout chain.
8. **T+0.5s / +2s** (UI only): command client delays for stats (`CommandClient.swift:68,101`).

### Where each second is wasted

- Preference writes in connect path (`VPNManager.connect`, `30-41`, `44-47`).
- Blocking startup call (`ExtensionProvider`, `189-191`).
- DNS remote detour through unstable/blocked proxy (`singbox.rs`, `101`, `107`).
- Sequential control-plane fallbacks with 5-10s timeouts (`APIClient.dataWithFallback`, `59-64`, `81`, `93`).
- Forced 1s server-switch downtime (`AppState.selectServer`, `160`).

### How to achieve <1s practical connect

1. Pre-create/enable VPN profile during onboarding, not first connect.
2. Remove on-demand preference writes from hot path (or batch once).
3. Stop logging full config and set production log level.
4. Use FakeIP + direct split DNS to avoid remote DNS handshake on first request.
5. Avoid reconnect for server switch; use command API `selectOutbound` live.
6. Keep 2-3 pre-validated fast outbounds in `Auto` with 10-20s urltest interval.
7. Ensure first outbound candidates are IP-based (no DNS needed to bootstrap).

---

## 5. PROTOCOL GAPS

### Missing or effectively missing in generated mobile config

- **VLESS WS CDN fallback**: protocol exists in codebase but omitted by `singbox.rs` filtering.
- **VLESS gRPC**: server-side hints exist, but client outbound generation path does not provide robust gRPC config.
- **Shadowsocks/TUIC emergency paths**: absent from mobile output pipeline.
- **Carrier-specific SNI fanout**: logic exists partially (`get_user_snis`) but not used when generating mobile outbounds.

### CDN fallback via Cloudflare Workers (strategy)

1. Add `vless_cdn` generation in mobile config path (remove protocol hard filter).
2. Provision multiple CDN front domains/subdomains per carrier.
3. Generate WS + gRPC CDN outbounds with distinct Host/SNI pairs.
4. Include CDN outbounds in dedicated `auto-cdn` urltest and global `auto-all`.

### Multi-SNI implementation strategy

- Extend server schema:
  - `sni_pool_by_carrier` map, e.g. `{"megafon":[...],"beeline":[...],"default":[...]}`.
- On config generation:
  - Build N variants per server (IP x SNI x transport).
  - Tag format: `<region>-<ip>-<transport>-<sni-key>`.
- On iOS:
  - Detect carrier (if available) or network traits and prefer corresponding SNI group.

### Why multiplexing cannot be used with Vision flow

- `xtls-rprx-vision` is a specialized TLS-layer flow for VLESS Reality.
- sing-box/xray constraints make Vision flow incompatible with standard multiplex settings on same outbound.
- Practical result: for Vision routes, rely on parallel connection pools and urltest group selection, not mux.

---

## 6. SING-BOX CONFIG (OPTIMAL TEMPLATE)

Below is a complete target JSON template for generated mobile config (replace `__PLACEHOLDER__` values). It includes FakeIP, split DNS, multi-group outbounds, and protocol fallback.

```json
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "independent_cache": true,
    "strategy": "prefer_ipv4",
    "fakeip": {
      "enabled": true,
      "inet4_range": "198.18.0.0/15",
      "inet6_range": "fc00::/18"
    },
    "servers": [
      {
        "tag": "dns-local",
        "address": "local",
        "detour": "direct"
      },
      {
        "tag": "dns-direct-ru",
        "address": "https://77.88.8.8/dns-query",
        "detour": "direct"
      },
      {
        "tag": "dns-remote",
        "address": "https://1.1.1.1/dns-query",
        "detour": "proxy-chain"
      },
      {
        "tag": "dns-fakeip",
        "address": "fakeip"
      }
    ],
    "rules": [
      {
        "domain_suffix": ["ru", "su", "xn--p1ai"],
        "server": "dns-direct-ru"
      },
      {
        "rule_set": ["geosite-ru"],
        "server": "dns-direct-ru"
      },
      {
        "domain_suffix": ["lan", "local"],
        "server": "dns-local"
      },
      {
        "outbound": "direct",
        "server": "dns-local"
      },
      {
        "server": "dns-fakeip"
      }
    ],
    "final": "dns-remote"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "utun",
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
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "__REALITY_PUBLIC_KEY__",
          "short_id": "__SHORT_ID__"
        }
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
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "__REALITY_PUBLIC_KEY__",
          "short_id": "__SHORT_ID__"
        }
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
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "__REALITY_PUBLIC_KEY__",
          "short_id": "__SHORT_ID__"
        }
      }
    },
    {
      "type": "vless",
      "tag": "cdn-ws-1",
      "server": "__CDN_DOMAIN_1__",
      "server_port": 443,
      "uuid": "__UUID__",
      "tls": {
        "enabled": true,
        "server_name": "__CDN_DOMAIN_1__",
        "utls": { "enabled": true, "fingerprint": "chrome" }
      },
      "transport": {
        "type": "ws",
        "path": "/vless-ws",
        "headers": {
          "Host": "__CDN_DOMAIN_1__"
        }
      }
    },
    {
      "type": "vless",
      "tag": "cdn-grpc-1",
      "server": "__CDN_DOMAIN_2__",
      "server_port": 443,
      "uuid": "__UUID__",
      "tls": {
        "enabled": true,
        "server_name": "__CDN_DOMAIN_2__",
        "utls": { "enabled": true, "fingerprint": "chrome" }
      },
      "transport": {
        "type": "grpc",
        "service_name": "grpc"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-de-1",
      "server": "__HY2_IP_1__",
      "server_port": 443,
      "password": "__HY2_PASSWORD__",
      "tls": {
        "enabled": true,
        "server_name": "__HY2_SNI__",
        "insecure": false
      },
      "obfs": {
        "type": "salamander",
        "password": "__HY2_OBFS_PASSWORD__"
      }
    },
    {
      "type": "urltest",
      "tag": "auto-reality",
      "outbounds": [
        "reality-de-1-eh",
        "reality-de-1-megafon",
        "reality-nl-1-event"
      ],
      "url": "https://cp.cloudflare.com/generate_204",
      "interval": "20s",
      "tolerance": 30,
      "idle_timeout": "30m"
    },
    {
      "type": "urltest",
      "tag": "auto-cdn",
      "outbounds": ["cdn-ws-1", "cdn-grpc-1"],
      "url": "https://cp.cloudflare.com/generate_204",
      "interval": "20s",
      "tolerance": 30,
      "idle_timeout": "30m"
    },
    {
      "type": "urltest",
      "tag": "auto-hy2",
      "outbounds": ["hy2-de-1"],
      "url": "https://cp.cloudflare.com/generate_204",
      "interval": "20s",
      "tolerance": 50,
      "idle_timeout": "30m"
    },
    {
      "type": "urltest",
      "tag": "auto-all",
      "outbounds": ["auto-reality", "auto-cdn", "auto-hy2"],
      "url": "https://cp.cloudflare.com/generate_204",
      "interval": "15s",
      "tolerance": 20,
      "idle_timeout": "30m"
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
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": {
      "server": "dns-local",
      "strategy": "prefer_ipv4"
    },
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
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" },
      { "domain_suffix": ["ru", "su", "xn--p1ai"], "outbound": "direct" },
      { "rule_set": ["geosite-ru", "geoip-ru"], "outbound": "direct" }
    ],
    "final": "Proxy"
  }
}
```

---

## 7. IMPLEMENTATION ROADMAP

### Priority 0 (same day, blocker fixes)

1. **Fix DNS death loop and hardcoded endpoints in `singbox.rs`**
   - Remove hardcoded HY2 block.
   - Generate outbounds from protocol registry (`vless_reality`, `vless_cdn`, `hysteria2`).
   - Add FakeIP + split DNS rules.

2. **Stop insecure fallback transport in iOS API client**
   - Remove trust-all delegate.
   - Remove HTTP fallback constants.

3. **Stop logging full config in extension**
   - Redact or remove full config log lines.

Estimated effort: **6-10 hours** including verification on device.

### Priority 1 (1-3 days)

1. **Expand server schema and config generation** (`types.rs`, `engine.rs`, `chameleon-config/lib.rs`).
2. **Add multi-SNI per server/carrier fanout in `vless_reality.rs` and `singbox.rs`.**
3. **Add CDN WS/gRPC outbound generation path in mobile config.**
4. **Switch server change to live outbound select (no reconnect)** in iOS app.

Estimated effort: **2-4 days**.

### Priority 2 (1 week)

1. **Add TUIC or Shadowsocks emergency transport.**
2. **Implement health-scored fallback orchestration and telemetry feedback.**
3. **Add endpoint rotation API (not hardcoded in app constants).**

Estimated effort: **5-7 days**.

### File-by-file concrete changes + snippets

#### `backend/crates/chameleon-vpn/src/singbox.rs`

```rust
// Before: filter only vless_reality
for proto in registry.enabled() {
    for srv in servers {
        for opts in build_outbound_variants(proto.name(), srv, user) {
            let tag = format_tag(srv, &opts);
            if let Some(ob) = proto.singbox_outbound(&tag, srv, user, &opts) {
                outbounds.push(ob);
                tags.push(tag);
            }
        }
    }
}
```

```rust
let dns = json!({
    "independent_cache": true,
    "fakeip": {"enabled": true, "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18"},
    "servers": [
        {"tag":"dns-local","address":"local","detour":"direct"},
        {"tag":"dns-direct-ru","address":"https://77.88.8.8/dns-query","detour":"direct"},
        {"tag":"dns-remote","address":"https://1.1.1.1/dns-query","detour":"proxy-chain"},
        {"tag":"dns-fakeip","address":"fakeip"}
    ],
    "rules": [
        {"domain_suffix":["ru","su","xn--p1ai"],"server":"dns-direct-ru"},
        {"server":"dns-fakeip"}
    ],
    "final": "dns-remote"
});
```

#### `backend/crates/chameleon-vpn/src/protocols/vless_reality.rs`

```rust
match transport {
    "tcp" => out["flow"] = json!("xtls-rprx-vision"),
    "grpc" => {
        out["transport"] = json!({"type":"grpc", "service_name": opts.service_name.as_deref().unwrap_or("grpc")});
    }
    "ws" => {
        out["transport"] = json!({"type":"ws", "path": opts.path.as_deref().unwrap_or("/ws"), "headers": {"Host": sni}});
    }
    _ => {}
}
```

- Replace hardcoded `2097` with settings-driven port.
- Split `xhttp` and `grpc` correctly in inbound generation.

#### `backend/crates/chameleon-vpn/src/protocols/types.rs`

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerConfig {
    pub key: String,
    pub host: String,
    pub domain: String,
    pub ports: std::collections::HashMap<String, u16>,
    pub snis: Vec<String>,
    pub cdn_domains: Vec<String>,
    pub flag: String,
    pub name: String,
}
```

```rust
#[derive(Debug, Clone, Default)]
pub struct OutboundOpts {
    pub transport: Option<String>,
    pub sni: Option<String>,
    pub service_name: Option<String>,
    pub path: Option<String>,
    pub carrier: Option<String>,
}
```

#### `backend/crates/chameleon-vpn/src/protocols/mod.rs`

- Keep module list; add test asserting mobile generator consumes more than one protocol class.

#### `backend/crates/chameleon-vpn/src/engine.rs`

```rust
fn stats_api_inbound(port: u16) -> serde_json::Value {
    json!({"tag":"api","listen":"127.0.0.1","port":port,"protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}})
}
```

```rust
let servers: Vec<serde_json::Value> = match serde_json::from_str(&self.settings.vpn_servers_raw) {
    Ok(v) => v,
    Err(e) => {
        error!(error=%e, "VPN_SERVERS parse failed");
        vec![]
    }
};
```

- Move blocking FS operations to `tokio::fs`.

#### `backend/crates/chameleon-config/src/lib.rs`

```rust
if self.reality_public_key.is_empty() {
    errors.push("REALITY_PUBLIC_KEY is required for VLESS Reality".into());
}
if self.vpn_servers_raw.is_empty() {
    errors.push("VPN_SERVERS is required".into());
}
if self.reality_snis.len() < 3 {exec
/bin/zsh -lc "cat > CODEX_ANALYSIS.md <<'EOF'
# Chameleon VPN Technical Audit

Date: 2026-04-05
Scope: deep audit of 13 requested files.

---

## 1. CODE-LEVEL BUG REPORT

### 1.1 "'`backend/crates/chameleon-vpn/src/singbox.rs`

- **[CRITICAL] Only `vless_reality` is generated, other protocol plugins are ignored** (`19-29`).
  - `generate_config()` filters `proto.name() != "vless_reality"`, so `vless_cdn`, `hysteria2`, `warp`, `anytls`, `naiveproxy`, etc. in the registry never participate in mobile config generation.
  - Impact: architecture claims multi-protocol but runtime config is effectively single-protocol (+ one hardcoded HY2 entry).

- **[CRITICAL] Hardcoded HY2 endpoint and secret in client config generator** (`63-76`).
  - Fixed IP (`162.19.242.30`), fixed port (`8443`), fixed password (`ChameleonHy2-2026-Secure`), fixed SNI (`ads.x5.ru`), and `insecure: true` are hardcoded.
  - Impact: single censorship target, secret exposure in source, zero environment-driven rotation, TLS verification bypass.

- **[CRITICAL] DNS remote resolver detours through `Auto` proxy group** (`101`, `107`).
  - `dns-remote` uses detour `Auto`, and `final` is `dns-remote`.
  - If `Auto` picks blocked DE TCP:2096 or blocked UDP:8443 HY2 path, DNS stalls and all domain traffic stalls with it.

- **[CRITICAL] DNS bootstrap loop / dependency cycle** (`101-107`, `121-126`).
  - DNS for user traffic depends on proxy connectivity (`Auto`), proxy connectivity itself needs DNS for many targets, and route hijacks DNS (`hijack-dns`), creating repeated timeout chains.

- **[HIGH] Fragile outbound mutation by positional index assumptions** (`77-93`).
  - Code assumes `all_outbounds[0]` is selector and `all_outbounds[1]` is urltest.
  - For `tags.len()==1` there is no urltest, and for `tags.len()==0` `all_outbounds[0]` is HY2 outbound.
  - Impact: inconsistent group membership and hidden behavior drift when server count changes.

- **[HIGH] No generation of multi-SNI/per-carrier outbound variants** (`21-24`).
  - `OutboundOpts::default()` is always used (TCP + default SNI), while protocol code supports SNI override.
  - Impact: censorship adaptation unavailable in actual generated mobile config.

- **[HIGH] `dns-direct` uses DoH to `8.8.8.8` over direct path** (`102`).
  - In hostile networks this can be throttled/blocked; there is no local/system resolver fallback.

- **[MEDIUM] Server tags may collide** (`22`).
  - Tag uses `"{flag} {name}"`; duplicate country/name combinations produce non-unique tags and unstable selector behavior.

- **[MEDIUM] Urltest target may be blocked/slow** (`48`).
  - Single probe URL `https://www.gstatic.com/generate_204` is a weak health oracle for RU carrier conditions.

- **[LOW] Fixed URL test interval is too long for hostile networks** (`49`).
  - `300s` delays adaptation after a path is blocked.

### 1.2 `backend/crates/chameleon-vpn/src/protocols/vless_reality.rs`

- **[CRITICAL] XHTTP/GRPC inbound mismatch and hardcoded port** (`126-127`).
  - `"VLESS XHTTP REALITY"` uses hardcoded port `2097`, and `"VLESS XHTTP H2 REALITY"` also uses network `xhttp` (not `grpc`) on `grpc_port`.
  - Impact: transport matrix is inconsistent; expected gRPC path is not actually produced as gRPC.

- **[HIGH] `relay_servers_raw` is loaded but unused** (`18`, `32`).
  - Indicates partially implemented relay architecture; no runtime effect.

- **[HIGH] No ws/grpc transport generation for sing-box outbounds** (`148-174`).
  - Only `tcp` and pseudo-`xhttp` path are implemented.
  - Impact: missing CDN-friendly transports in mobile config.

- **[HIGH] Transport-specific port choice is weak** (`153`).
  - If `server.port != 0`, that port overrides all transports, potentially forcing xhttp/grpc onto tcp-only port.

- **[MEDIUM] `dest` uses first SNI only** (`23-25`, `43-45`).
  - Multiple SNI list is advertised in `serverNames`, but `dest` is pinned to first entry.
  - Impact: reduced realism/diversity and possible fingerprinting.

- **[MEDIUM] Single static fingerprint** (`9`, `164`).
  - Fixed `chrome` fingerprint across all users/servers.
  - Impact: easier traffic profiling.

- **[LOW] `xhttp` outbound payload likely too minimal** (`171-173`).
  - Only method is set; path/host/service fields are absent.

### 1.3 `backend/crates/chameleon-vpn/src/protocols/types.rs`

- **[HIGH] `ServerConfig` is too flat for censorship-era routing** (`9-16`).
  - Single `host/port/domain` cannot represent per-transport ports, per-carrier SNI pools, CDN aliases, health metadata.

- **[MEDIUM] `effective_host()` always prefers domain over IP** (`68-70`).
  - No policy to force IP during DNS impairment, despite host IP being present.

- **[MEDIUM] `OutboundOpts.network` is unused dead field** (`63`).
  - Signals incomplete transport control path.

- **[LOW] `remark()` blindly appends suffix with fixed spacing** (`78-79`).

### 1.4 `backend/crates/chameleon-vpn/src/protocols/mod.rs`

- **[HIGH, architectural wiring mismatch] Protocol modules are exposed (`3-12`) but mobile config path hard-filters to one protocol in `singbox.rs` (`19-20`).**
  - Not a syntax bug here, but this module layout masks functional under-utilization.

### 1.5 `backend/crates/chameleon-vpn/src/engine.rs`

- **[CRITICAL] Xray API inbound listens on `0.0.0.0`** (`207-208`).
  - Stats/handler API is network-exposed unless external firewall blocks it.

- **[HIGH] Private IP traffic is routed to `BLOCK`** (`86`, `120`).
  - `geoip:private -> BLOCK` breaks local/LAN/private services and some control-plane connectivity.

- **[HIGH] DNS config for xray control plane is static/global only** (`97`, `124`).
  - Hardcoded `1.1.1.1`, `8.8.8.8`; no country-aware resolver strategy.

- **[HIGH] Silent parse failure of `VPN_SERVERS`** (`134`).
  - `serde_json::from_str(...).unwrap_or_default()` converts parse errors into empty server list with no diagnostics.

- **[MEDIUM] Blocking FS writes in async functions** (`53`, `57`, `155-157`).
  - `std::fs::*` used inside async methods may stall executor threads.

- **[MEDIUM] Serialization fallback can write empty config** (`57`, `156`).
  - `to_string_pretty(...).unwrap_or_default()` can produce empty file on serialization error.

- **[MEDIUM] Added fixed 1s sleep after reload** (`166`).
  - Deterministic startup latency tax.

- **[LOW] `XRAY_CONFIG_DIR.is_dir()` gate can skip config generation unexpectedly** (`51-61`).

### 1.6 `backend/crates/chameleon-config/src/lib.rs`

- **[CRITICAL] Security-critical secrets auto-randomize on missing env** (`253-259`, `348-349`).
  - Session/JWT/cluster secrets silently rotate on restart if env is missing.
  - Impact: token invalidation, cluster partitioning, hard-to-debug auth churn.

- **[HIGH] Default SNI/ports are weak against censorship concentration** (`273`, `275-279`, `283`).
  - Single default Reality SNI and static default ports.

- **[HIGH] Validation is incomplete** (`358-389`).
  - Validates `REALITY_PRIVATE_KEY` but not `REALITY_PUBLIC_KEY`, not `VPN_SERVERS`, not protocol credentials needed for enabled protocols.

- **[MEDIUM] `parse_csv_ints()` silently drops malformed values** (`25-29`).
  - Can corrupt config intent without warning.

- **[MEDIUM] `dotenvy::dotenv()` always called in load path** (`243`).
  - Hidden env precedence side-effects in non-dev environments.

- **[LOW] `xray_version` default appears non-standard** (`335`).

### 1.7 `apple/ChameleonVPN/Models/AppState.swift`

- **[CRITICAL] Server switching forces full reconnect with hardcoded downtime** (`156-162`).
  - Disconnect + sleep(1s) + reconnect rather than in-place outbound switch.
  - Impact: avoidable 1s+ interruption and extra tunnel churn.

- **[HIGH] `toggleVPN()` lacks re-entrancy guard** (`99-132`).
  - No early return when `vpnManager.isProcessing`; rapid taps can trigger racey connect/disconnect sequences.

- **[HIGH] “Silent” config update surfaces user-visible error state** (`88-94`).
  - Any transient fetch failure can set `errorMessage`, degrading UX stability.

- **[HIGH] Selector rewrite modifies all selector outbounds indiscriminately** (`174-177`).
  - If config includes multiple selector groups, all defaults are overwritten.

- **[MEDIUM] Corruption heuristic can delete potentially valid minimal configs** (`48-65`).
  - Assumes selector/urltest must exist.

- **[MEDIUM] Status observer lifecycle not explicitly removed** (`18`, `190-197`).

### 1.8 `apple/ChameleonVPN/Models/APIClient.swift`

- **[CRITICAL] TLS trust-all fallback session enables MITM** (`40-50`, `64`, `82`, `94`).
  - Entire cert chain is bypassed for relay/IP fallbacks.

- **[CRITICAL] Fallback URLs use plain HTTP** (via constants used in `77-94`).
  - Token-bearing requests can traverse unencrypted channels.

- **[HIGH] `accessToken` argument is ignored in `fetchConfig()`** (`168`, `174-178`).
  - Comment says Bearer supported, implementation never sets `Authorization`.

- **[HIGH] Fallback URL rewriting is string-based** (`77-90`).
  - Fragile and can produce invalid endpoints or accidental path mutation.

- **[MEDIUM] No fallback path for several auth APIs** (`141-143`, `212`, `234`, `256`).
  - `activateCode`, Apple auth, and refresh use primary session only.

- **[LOW] Tight request timeouts + sequential fallback magnify cold-start latency** (`59`, `63`, `81`, `93`).

### 1.9 `apple/ChameleonVPN/Models/ConfigStore.swift`

- **[HIGH] Config parser builds duplicate/ambiguous group view** (`165-221`).
  - It adds both urltest and selector groups directly, which can mismatch intended UX model.

- **[MEDIUM] `metaOutboundTypes` is dead code** (`15-17`).

- **[MEDIUM] Selector group includes non-proxy members (e.g., `Auto`) as selectable server items** (`199-210`).

- **[LOW] `clear()` redundantly deletes username twice** (`130`, `134`).

### 1.10 `apple/ChameleonVPN/Models/VPNManager.swift`

- **[HIGH] `load()` picks first saved tunnel manager, not guaranteed app-owned profile** (`17-20`).

- **[HIGH] On-demand preferences are toggled during connect path** (`44-47`).
  - Preference writes add startup latency and can fail silently (`try?`).

- **[MEDIUM] `disconnect()` performs async preference save without waiting** (`67-71`).
  - Race between on-demand state save and tunnel stop.

- **[MEDIUM] Observer lifecycle cleanup only in `resetProfile()`** (`84-87`, `105-113`).

- **[LOW] `sendMessage()` has no timeout guard** (`92-103`).

### 1.11 `apple/ChameleonVPN/Models/CommandClient.swift`

- **[HIGH] Built-in connect delays inflate perceived readiness** (`68`, `101`).
  - Fixed 0.5s delay + 2s retry delay before marking stats unavailable.

- **[MEDIUM] Class is not isolated to MainActor; mutable shared state touched across task/main queues** (`11-38`, `64-123`, `217-295`).
  - Token checks reduce stale updates but do not fully eliminate data races.

- **[MEDIUM] No automatic re-connect after post-connect disconnect event** (`226-234`).

- **[LOW] Group interpretation logic assumes specific topology** (`191-204`).

### 1.12 `apple/PacketTunnel/ExtensionProvider.swift`

- **[CRITICAL] Full VPN config (credentials included) logged to file** (`50-53`).
  - Sensitive material at rest in app group container.

- **[HIGH] Persisted start config has highest precedence over file config** (`33-43`, `229-235`).
  - Stale persisted config can shadow fresher downloaded file indefinitely.

- **[HIGH] Debug mode enabled in production tunnel runtime** (`139`).
  - Higher overhead + verbose logs in security-sensitive process.

- **[MEDIUM] `startOrReloadService` is synchronous/blocking call in startup path** (`189-191`).
  - Contributes directly to long connect times.

- **[MEDIUM] Shared defaults store config plaintext** (`229-231`).

- **[LOW] Completion callback is invoked from background queue** (`60-71`).

### 1.13 `apple/Shared/Constants.swift`

- **[CRITICAL] Hardcoded single fallback IP + single relay IP** (`13`, `16`).
  - Trivial blocking target set.

- **[CRITICAL] HTTP fallback/relay endpoints** (`13`, `16`).
  - No TLS for fallback control-plane traffic.

- **[HIGH] Static deployment values in source** (`8-39`).
  - Requires app release for endpoint rotation.

---

## 2. ARCHITECTURE FLAWS

### Why current architecture fails under Russian censorship

1. **Single-path dependency graph**
   - Data plane is mostly Reality TCP + one hardcoded HY2 path.
   - Control plane (mobile config + DNS) also leans on same small endpoint set.
   - When DE IP/ports are filtered, both DNS and traffic stall.

2. **No carrier-specific adaptation**
   - Despite code hints for multiple SNIs (`vless_reality.rs:23, 89-96`), generated mobile config does not fan out per-carrier SNI variants.
   - One dominant SNI (`ads.x5.ru`) is fingerprintable and blockable.

3. **No real CDN fallback in generated config**
   - `vless_cdn` exists in protocol registry, but `singbox.rs` excludes it.
   - In practice users do not receive Cloudflare/WS/gRPC backup path from mobile endpoint.

4. **DNS and tunnel bootstrap are coupled to blocked upstream paths**
   - `dns-remote` detours through `Auto` which can choose blocked transport.
   - This converts route failure into universal app failure.

### Single points of failure

- Single DE IP for major paths (`162.19.242.30` hardcoded in app/client config).
- Single HY2 UDP port (`8443`) and single Reality TCP port (`2096` default).
- Single SNI default.
- Single health URL (`gstatic`) for urltest.
- Single fallback relay IP in app constants.

### Missing redundancy

- No multi-region IP pool selection in mobile config.
- No per-carrier SNI pool routing.
- No dual-stack transport matrix in generated config (Reality + CDN WS + gRPC + TUIC/SS fallback).
- No weighted failover policy with short health intervals.
- No independent DNS plane that survives proxy-plane outages.

---

## 3. DNS DEEP DIVE

### Current DNS resolution path (exact runtime flow)

1. User presses connect in app (`AppState.toggleVPN`, `99-132`), app passes config string into `VPNManager.connect()` (`51-56`).
2. Packet tunnel starts; extension loads config from options / persisted defaults / file (`ExtensionProvider.startTunnel`, `31-43`).
3. `startOrReloadService` starts sing-box (`189-191`).
4. During TUN setup, iOS DNS is forced through tunnel (`ExtensionPlatformInterface.buildTunnelSettings`, `217-220`, `matchDomains=[""]`).
5. sing-box inbound route has `{"protocol":"dns","action":"hijack-dns"}` (`singbox.rs`, `125`), so all DNS queries are intercepted.
6. DNS policy:
   - servers:
     - `dns-remote`: `https://1.1.1.1/dns-query`, detour=`Auto` (`101`)
     - `dns-direct`: `https://8.8.8.8/dns-query`, detour=`direct` (`102`)
   - rules: only outbound=`direct` -> `dns-direct` (`105`)
   - final: `dns-remote` (`107`)
7. For typical proxied app traffic, query does **not** match outbound=`direct`, so it goes to `dns-remote` via `Auto`.
8. `Auto` may resolve to blocked DE Reality or blocked HY2 path; DNS waits until transport timeout.
9. iOS resolver retries; each retry re-enters same chain, producing perceived “infinite retry / DNS death loop”.

### Why this creates retry loops and 30-60s stalls

- DNS success depends on tunnel success (`dns-remote -> Auto`).
- Tunnel success for many targets depends on DNS and initial connect path health.
- In blocked environments, repeated connect timeouts accumulate per query.
- No FakeIP fast response path exists, so every domain waits on remote DoH path availability.

### Correct DNS strategy (with FakeIP + split DNS)

Design goals:

- **Immediate DNS answers** for proxied domains: FakeIP.
- **Bypass tunnel dependency** for Russian/local domains: direct resolver path.
- **No circular dependency** between remote DNS and blocked proxy path.

Proposed logic:

1. Enable `dns.fakeip` ranges.
2. Add local/direct DNS servers (`local`, regional DoH/DoT reachable directly).
3. Add remote DNS server detoured via resilient proxy group (`proxy-chain`).
4. DNS rules:
   - `.ru`, `.su`, `xn--p1ai`, and RU geosite -> `dns-direct-ru`.
   - LAN/private reverse and local domains -> `dns-local`.
   - All remaining domains -> `dns-fakeip`.
5. Route rules:
   - RU domains/IPs -> `direct`.
   - All other traffic -> `Proxy`.

### Split DNS implementation detail

- Use suffix + rule-set matching, not only suffix:
  - suffix catches obvious TLDs.
  - rule-set catches RU services hosted under non-`.ru` domains.
- Keep `route.default_domain_resolver` on direct/local resolver so outbound server names can resolve even if proxy path is down.

---

## 4. CONNECTION TIMELINE

### Current timeline (best-effort based on code path)

1. **T+0ms**: user taps VPN button (`AppState.toggleVPN`).
2. **T+50-1500ms**: `VPNManager.connect()` may create profile, save/load preferences (`28-41`).
3. **T+200-800ms**: optional on-demand preference write (`44-47`).
4. **T+0.2-1.0s**: extension `startTunnel()` loads config + logs full JSON (`31-53`).
5. **T+0.3-1.5s**: `startSingBox()` setup + command server init (`132-178`).
6. **T+0.3-1.5s**: blocking `startOrReloadService()` and `setTunnelNetworkSettings` path (`189-191`, Platform `58-69`).
7. **T+1-30s+**: first domain query goes through `dns-remote` via `Auto`; blocked path causes timeout chain.
8. **T+0.5s / +2s** (UI only): command client delays for stats (`CommandClient.swift:68,101`).

### Where each second is wasted

- Preference writes in connect path (`VPNManager.connect`, `30-41`, `44-47`).
- Blocking startup call (`ExtensionProvider`, `189-191`).
- DNS remote detour through unstable/blocked proxy (`singbox.rs`, `101`, `107`).
- Sequential control-plane fallbacks with 5-10s timeouts (`APIClient.dataWithFallback`, `59-64`, `81`, `93`).
- Forced 1s server-switch downtime (`AppState.selectServer`, `160`).

### How to achieve <1s practical connect

1. Pre-create/enable VPN profile during onboarding, not first connect.
2. Remove on-demand preference writes from hot path (or batch once).
3. Stop logging full config and set production log level.
4. Use FakeIP + direct split DNS to avoid remote DNS handshake on first request.
5. Avoid reconnect for server switch; use command API `selectOutbound` live.
6. Keep 2-3 pre-validated fast outbounds in `Auto` with 10-20s urltest interval.
7. Ensure first outbound candidates are IP-based (no DNS needed to bootstrap).

---

## 5. PROTOCOL GAPS

### Missing or effectively missing in generated mobile config

- **VLESS WS CDN fallback**: protocol exists in codebase but omitted by `singbox.rs` filtering.
- **VLESS gRPC**: server-side hints exist, but client outbound generation path does not provide robust gRPC config.
- **Shadowsocks/TUIC emergency paths**: absent from mobile output pipeline.
- **Carrier-specific SNI fanout**: logic exists partially (`get_user_snis`) but not used when generating mobile outbounds.

### CDN fallback via Cloudflare Workers (strategy)

1. Add `vless_cdn` generation in mobile config path (remove protocol hard filter).
2. Provision multiple CDN front domains/subdomains per carrier.
3. Generate WS + gRPC CDN outbounds with distinct Host/SNI pairs.
4. Include CDN outbounds in dedicated `auto-cdn` urltest and global `auto-all`.

### Multi-SNI implementation strategy

- Extend server schema:
  - `sni_pool_by_carrier` map, e.g. `{"megafon":[...],"beeline":[...],"default":[...]}`.
- On config generation:
  - Build N variants per server (IP x SNI x transport).
  - Tag format: `<region>-<ip>-<transport>-<sni-key>`.
- On iOS:
  - Detect carrier (if available) or network traits and prefer corresponding SNI group.

### Why multiplexing cannot be used with Vision flow

- `xtls-rprx-vision` is a specialized TLS-layer flow for VLESS Reality.
- sing-box/xray constraints make Vision flow incompatible with standard multiplex settings on same outbound.
- Practical result: for Vision routes, rely on parallel connection pools and urltest group selection, not mux.

---

## 6. SING-BOX CONFIG (OPTIMAL TEMPLATE)

Below is a complete target JSON template for generated mobile config (replace `__PLACEHOLDER__` values). It includes FakeIP, split DNS, multi-group outbounds, and protocol fallback.

```json
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "independent_cache": true,
    "strategy": "prefer_ipv4",
    "fakeip": {
      "enabled": true,
      "inet4_range": "198.18.0.0/15",
      "inet6_range": "fc00::/18"
    },
    "servers": [
      {
        "tag": "dns-local",
        "address": "local",
        "detour": "direct"
      },
      {
        "tag": "dns-direct-ru",
        "address": "https://77.88.8.8/dns-query",
        "detour": "direct"
      },
      {
        "tag": "dns-remote",
        "address": "https://1.1.1.1/dns-query",
        "detour": "proxy-chain"
      },
      {
        "tag": "dns-fakeip",
        "address": "fakeip"
      }
    ],
    "rules": [
      {
        "domain_suffix": ["ru", "su", "xn--p1ai"],
        "server": "dns-direct-ru"
      },
      {
        "rule_set": ["geosite-ru"],
        "server": "dns-direct-ru"
      },
      {
        "domain_suffix": ["lan", "local"],
        "server": "dns-local"
      },
      {
        "outbound": "direct",
        "server": "dns-local"
      },
      {
        "server": "dns-fakeip"
      }
    ],
    "final": "dns-remote"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "utun",
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
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "__REALITY_PUBLIC_KEY__",
          "short_id": "__SHORT_ID__"
        }
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
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "__REALITY_PUBLIC_KEY__",
          "short_id": "__SHORT_ID__"
        }
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
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "__REALITY_PUBLIC_KEY__",
          "short_id": "__SHORT_ID__"
        }
      }
    },
    {
      "type": "vless",
      "tag": "cdn-ws-1",
      "server": "__CDN_DOMAIN_1__",
      "server_port": 443,
      "uuid": "__UUID__",
      "tls": {
        "enabled": true,
        "server_name": "__CDN_DOMAIN_1__",
        "utls": { "enabled": true, "fingerprint": "chrome" }
      },
      "transport": {
        "type": "ws",
        "path": "/vless-ws",
        "headers": {
          "Host": "__CDN_DOMAIN_1__"
        }
      }
    },
    {
      "type": "vless",
      "tag": "cdn-grpc-1",
      "server": "__CDN_DOMAIN_2__",
      "server_port": 443,
      "uuid": "__UUID__",
      "tls": {
        "enabled": true,
        "server_name": "__CDN_DOMAIN_2__",
        "utls": { "enabled": true, "fingerprint": "chrome" }
      },
      "transport": {
        "type": "grpc",
        "service_name": "grpc"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-de-1",
      "server": "__HY2_IP_1__",
      "server_port": 443,
      "password": "__HY2_PASSWORD__",
      "tls": {
        "enabled": true,
        "server_name": "__HY2_SNI__",
        "insecure": false
      },
      "obfs": {
        "type": "salamander",
        "password": "__HY2_OBFS_PASSWORD__"
      }
    },
    {
      "type": "urltest",
      "tag": "auto-reality",
      "outbounds": [
        "reality-de-1-eh",
        "reality-de-1-megafon",
        "reality-nl-1-event"
      ],
      "url": "https://cp.cloudflare.com/generate_204",
      "interval": "20s",
      "tolerance": 30,
      "idle_timeout": "30m"
    },
    {
      "type": "urltest",
      "tag": "auto-cdn",
      "outbounds": ["cdn-ws-1", "cdn-grpc-1"],
      "url": "https://cp.cloudflare.com/generate_204",
      "interval": "20s",
      "tolerance": 30,
      "idle_timeout": "30m"
    },
    {
      "type": "urltest",
      "tag": "auto-hy2",
      "outbounds": ["hy2-de-1"],
      "url": "https://cp.cloudflare.com/generate_204",
      "interval": "20s",
      "tolerance": 50,
      "idle_timeout": "30m"
    },
    {
      "type": "urltest",
      "tag": "auto-all",
      "outbounds": ["auto-reality", "auto-cdn", "auto-hy2"],
      "url": "https://cp.cloudflare.com/generate_204",
      "interval": "15s",
      "tolerance": 20,
      "idle_timeout": "30m"
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
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": {
      "server": "dns-local",
      "strategy": "prefer_ipv4"
    },
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
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" },
      { "domain_suffix": ["ru", "su", "xn--p1ai"], "outbound": "direct" },
      { "rule_set": ["geosite-ru", "geoip-ru"], "outbound": "direct" }
    ],
    "final": "Proxy"
  }
}
```

---

## 7. IMPLEMENTATION ROADMAP

### Priority 0 (same day, blocker fixes)

1. **Fix DNS death loop and hardcoded endpoints in `singbox.rs`**
   - Remove hardcoded HY2 block.
   - Generate outbounds from protocol registry (`vless_reality`, `vless_cdn`, `hysteria2`).
   - Add FakeIP + split DNS rules.

2. **Stop insecure fallback transport in iOS API client**
   - Remove trust-all delegate.
   - Remove HTTP fallback constants.

3. **Stop logging full config in extension**
   - Redact or remove full config log lines.

Estimated effort: **6-10 hours** including verification on device.

### Priority 1 (1-3 days)

1. **Expand server schema and config generation** (`types.rs`, `engine.rs`, `chameleon-config/lib.rs`).
2. **Add multi-SNI per server/carrier fanout in `vless_reality.rs` and `singbox.rs`.**
3. **Add CDN WS/gRPC outbound generation path in mobile config.**
4. **Switch server change to live outbound select (no reconnect)** in iOS app.

Estimated effort: **2-4 days**.

### Priority 2 (1 week)

1. **Add TUIC or Shadowsocks emergency transport.**
2. **Implement health-scored fallback orchestration and telemetry feedback.**
3. **Add endpoint rotation API (not hardcoded in app constants).**

Estimated effort: **5-7 days**.

### File-by-file concrete changes + snippets

#### `backend/crates/chameleon-vpn/src/singbox.rs`

```rust
// Before: filter only vless_reality
for proto in registry.enabled() {
    for srv in servers {
        for opts in build_outbound_variants(proto.name(), srv, user) {
            let tag = format_tag(srv, &opts);
            if let Some(ob) = proto.singbox_outbound(&tag, srv, user, &opts) {
                outbounds.push(ob);
                tags.push(tag);
            }
        }
    }
}
```

```rust
let dns = json!({
    "independent_cache": true,
    "fakeip": {"enabled": true, "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18"},
    "servers": [
        {"tag":"dns-local","address":"local","detour":"direct"},
        {"tag":"dns-direct-ru","address":"https://77.88.8.8/dns-query","detour":"direct"},
        {"tag":"dns-remote","address":"https://1.1.1.1/dns-query","detour":"proxy-chain"},
        {"tag":"dns-fakeip","address":"fakeip"}
    ],
    "rules": [
        {"domain_suffix":["ru","su","xn--p1ai"],"server":"dns-direct-ru"},
        {"server":"dns-fakeip"}
    ],
    "final": "dns-remote"
});
```

#### `backend/crates/chameleon-vpn/src/protocols/vless_reality.rs`

```rust
match transport {
    "tcp" => out["flow"] = json!("xtls-rprx-vision"),
    "grpc" => {
        out["transport"] = json!({"type":"grpc", "service_name": opts.service_name.as_deref().unwrap_or("grpc")});
    }
    "ws" => {
        out["transport"] = json!({"type":"ws", "path": opts.path.as_deref().unwrap_or("/ws"), "headers": {"Host": sni}});
    }
    _ => {}
}
```

- Replace hardcoded `2097` with settings-driven port.
- Split `xhttp` and `grpc` correctly in inbound generation.

#### `backend/crates/chameleon-vpn/src/protocols/types.rs`

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerConfig {
    pub key: String,
    pub host: String,
    pub domain: String,
    pub ports: std::collections::HashMap<String, u16>,
    pub snis: Vec<String>,
    pub cdn_domains: Vec<String>,
    pub flag: String,
    pub name: String,
}
```

```rust
#[derive(Debug, Clone, Default)]
pub struct OutboundOpts {
    pub transport: Option<String>,
    pub sni: Option<String>,
    pub service_name: Option<String>,
    pub path: Option<String>,
    pub carrier: Option<String>,
}
```

#### `backend/crates/chameleon-vpn/src/protocols/mod.rs`

- Keep module list; add test asserting mobile generator consumes more than one protocol class.

#### `backend/crates/chameleon-vpn/src/engine.rs`

```rust
fn stats_api_inbound(port: u16) -> serde_json::Value {
    json!({"tag":"api","listen":"127.0.0.1","port":port,"protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}})
}
```

```rust
let servers: Vec<serde_json::Value> = match serde_json::from_str(&self.settings.vpn_servers_raw) {
    Ok(v) => v,
    Err(e) => {
        error!(error=%e, "VPN_SERVERS parse failed");
        vec![]
    }
};
```

- Move blocking FS operations to `tokio::fs`.

#### `backend/crates/chameleon-config/src/lib.rs`

```rust
if self.reality_public_key.is_empty() {
    errors.push("REALITY_PUBLIC_KEY is required for VLESS Reality".into());
}
if self.vpn_servers_raw.is_empty() {
    errors.push("VPN_SERVERS is required".into());
}
if self.reality_snis.len() < 3 {
    warnings.push("REALITY_SNIS should contain multiple carrier-diverse SNIs".into());
}
```

- Remove random default for production secrets; fail fast in production.

#### `apple/ChameleonVPN/Models/AppState.swift`

```swift
func selectServer(groupTag: String, serverTag: String) {
    configStore.selectedServerTag = serverTag
    commandClient.selectOutbound(groupTag: groupTag, outboundTag: serverTag)
}
```

```swift
func toggleVPN() async {
    guard !vpnManager.isProcessing else { return }
    // existing logic
}
```

- Keep reconnect as fallback only if command API fails.

#### `apple/ChameleonVPN/Models/APIClient.swift`

```swift
if let token = accessToken, !token.isEmpty {
    request.setValue("Bearer '"\\(token)\", forHTTPHeaderField: \"Authorization\")
}
"'```

- Remove `InsecureDelegate`; use pinned cert/SPKI for fallback domains.
- Convert fallbacks to HTTPS only; keep explicit host allowlist.

#### `apple/ChameleonVPN/Models/ConfigStore.swift`

- Build one canonical UI group model (manual selector + resolved leaf proxies).
- Filter out meta outbounds from selectable server list.

#### `apple/ChameleonVPN/Models/VPNManager.swift`

```swift
func load() async throws {
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    manager = managers.first(where: {
        ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppConstants.tunnelBundleID
    })
    if manager != nil { observeStatus() }
}
```

- Move on-demand setup out of hot connect path.

#### `apple/ChameleonVPN/Models/CommandClient.swift`

- Remove fixed startup sleeps; use short retry loop with jitter and max deadline.
- Consider `@MainActor` wrapper state mutations for thread safety.

#### `apple/PacketTunnel/ExtensionProvider.swift`

```swift
// Remove full config logging
TunnelFileLogger.log("Config loaded, bytes='"\\(configJSON.utf8.count)\")
"'```

- Change precedence to: `options` > `file` > `persisted` (or include config version stamp).
- Set production runtime `debug = false`.

#### `apple/Shared/Constants.swift`

- Replace hardcoded fallback IPs with remote-signed endpoint manifest downloaded from API.
- Enforce HTTPS endpoints only.

---

## 8. iOS APP ISSUES (REQUESTED FOCUS)

### `AppState.swift` flow problems

- Connect path allows stale config-first behavior (`104-115`), delaying recovery from blocked endpoints.
- No debounce/re-entrancy protection for toggle (`99-132`).
- Server switch does full reconnect and fixed sleep (`156-162`) instead of live select.
- “Silent” update sets `errorMessage` (`88-94`), creating noisy UX under packet loss.

### `APIClient.swift` fallback issues

- Security model is broken by trust-all delegate (`40-50`) and HTTP fallbacks (from constants).
- `fetchConfig` ignores bearer token (`168-178`), making auth model inconsistent.
- Fallback construction via string replacement (`77-90`) is brittle and hard to verify.

### `VPNManager.swift` connection handling

- Hot path performs expensive preference saves (`30-41`, `44-47`).
- Manager selection is ambiguous (`17-20`).
- Disconnect path has async save race (`67-71`).

### `PacketTunnel` extension issues (`ExtensionProvider.swift`)

- Credential-bearing config logged verbatim (`50-53`).
- Blocking startup call + heavy debug setup slows connect (`139`, `189-191`).
- Persisted config precedence can trap clients on stale/bad config (`33-43`, `229-235`).

---

## Summary Diagnosis

Your observed field symptoms (blocked DE server, DNS timeout loops, slow load, failed speedtest, 10-30s connect) are directly explained by current code:

- mobile config generation is effectively **single-route**,
- DNS resolution is **tunnel-dependent via blocked paths**,
- fallback architecture exists in modules but is **not wired into generated config**,
- iOS control-plane fallback is **insecure and still single-point-heavy**.

The fastest recovery is: **(1) fix `singbox.rs` generation + FakeIP split DNS, (2) remove insecure iOS HTTP/TLS bypass fallbacks, (3) add CDN+multi-SNI variants into mobile config output immediately.**
EOF' in /Users/maksimtkachuk/кодим/VPN/chameleon succeeded in 52ms:

codex
The audit document has been written. I’m doing a quick verification pass on `CODEX_ANALYSIS.md` for completeness against your 8 required sections and line-referenced findings before I finalize.
exec
/bin/zsh -lc 'rg -n "''^## " CODEX_ANALYSIS.md && wc -l CODEX_ANALYSIS.md && sed -n '"'1,80p' CODEX_ANALYSIS.md && sed -n '780,980p' CODEX_ANALYSIS.md" in /Users/maksimtkachuk/кодим/VPN/chameleon succeeded in 52ms:
8:## 1. CODE-LEVEL BUG REPORT
245:## 2. ARCHITECTURE FLAWS
284:## 3. DNS DEEP DIVE
340:## 4. CONNECTION TIMELINE
373:## 5. PROTOCOL GAPS
407:## 6. SING-BOX CONFIG (OPTIMAL TEMPLATE)
686:## 7. IMPLEMENTATION ROADMAP
845:## 1. CODE-LEVEL BUG REPORT
1082:## 2. ARCHITECTURE FLAWS
1121:## 3. DNS DEEP DIVE
1177:## 4. CONNECTION TIMELINE
1210:## 5. PROTOCOL GAPS
1244:## 6. SING-BOX CONFIG (OPTIMAL TEMPLATE)
1523:## 7. IMPLEMENTATION ROADMAP
1750:## 8. iOS APP ISSUES (REQUESTED FOCUS)
1779:## Summary Diagnosis
    1792 CODEX_ANALYSIS.md
# Chameleon VPN Technical Audit

Date: 2026-04-05
