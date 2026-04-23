# Research: Open-Source VPN Apps Using sing-box on iOS

**Date:** 2026-04-05  
**Goal:** Extract actionable techniques from production VPN apps to improve Chameleon

---

## 1. Projects Analyzed

### 1.1 SagerNet/sing-box-for-apple (Official Client)
- **Repo:** https://github.com/SagerNet/sing-box-for-apple
- **Stars:** ~813
- **Architecture:** Swift, modular targets (SFI=iOS, SFM=macOS, SFT=tvOS)
- **Key insight:** The official reference implementation. Our app already mirrors its core pattern (thin `PacketTunnelProvider` subclass delegating to `ExtensionProvider`).

**Config Generation:** Configs are NOT generated client-side. Users import profiles (file, URL, QR). The app passes raw JSON to libbox via `CommandServer.startOrReloadService()`.

**DNS Strategy:** No special client-side DNS logic. DNS config comes from the imported profile.

**Server Selection:** Uses `OutboundGroup` struct with `tag`, `type` (selector/urltest), `selected`, `items[]` each with `urlTestDelay` (latency). Groups are exposed via libbox's gRPC command interface. The UI renders groups with latency badges.

**Fallback:** Config snapshot persisted to disk. On on-demand reconnect, last-known config is loaded. `reloadService()` allows hot-reload without full reconnect.

### 1.2 Hiddify (Multi-platform, Flutter + sing-box)
- **Repo:** https://github.com/hiddify/hiddify-app
- **Stars:** ~28.3k
- **Architecture:** Flutter/Dart (90%), with platform-native NetworkExtension on iOS
- **Key insight:** Most sophisticated config generation system among open-source clients.

**Config Generation Pipeline (CRITICAL):**
1. 60+ individual preference providers aggregated via Riverpod
2. `SingboxConfigOption` immutable data model generated from merged settings
3. Passed to Go-based `hiddify-sing-box` core via gRPC (port 17078 foreground, 17079 background)
4. Core validates JSON, starts service

**DNS Strategy:**
- **Dual-resolver architecture:** Remote DNS (tunneled) + Direct DNS (bypassed)
- Remote DNS options: UDP/TCP/DoH/DoT (e.g., `https://dns.cloudflare.com/dns-query`)
- Direct DNS options: Same protocols, independent config
- Per-region presets (Iran/China/Russia/Other) with automatic bypass rules

**Region-Specific (Russia):**
- Automatic region detection
- Region-based bypass rules applied to route config
- Russian traffic bypass for local services

**Fallback Mechanisms:**
- TLS Tricks: fragment packets (configurable size/sleep), mixed SNI case, padding
- WARP Integration: dual WireGuard instances through Cloudflare
- Multiplexing: h2mux/smux/yamux with configurable padding

**Connection Speed:**
- Delay-based node selection (URLTest)
- Profile-level config overrides for per-server tuning

### 1.3 Antizapret-sing-box (Russia-specific rulesets)
- **Repo:** https://github.com/savely-krasovsky/antizapret-sing-box
- **Purpose:** Generate sing-box rulesets from Roskomnadzor blocklists

**Strategy:**
- Default outbound = `direct` (bypass)
- Only blocked domains/IPs go through proxy
- Encrypted DNS (AdGuard) for blocked domains only
- Local DNS for everything else
- Outputs: `antizapret.srs` (binary), JSON, geoip.db, geosite.db

### 1.4 legiz-ru/sb-rule-sets (Russia rulesets)
- **Repo:** https://github.com/legiz-ru/sb-rule-sets
- **Rulesets available:**
  - `ru-bundle` — comprehensive (itdoginfo + no-russia-hosts + antifilter + rknasnblock)
  - `rknasnblock` — ASN-based blocking
  - `discord-voice-ip-list` — Discord voice IPs
  - `no-russia-hosts` — blocked domains
  - Available in JSON and binary `.srs` formats
  - 24-hour cache refresh

---

## 2. Key Techniques & Patterns

### 2.1 Multi-Protocol Support

**What top projects do:**
- Selector outbound wraps all protocols: user picks manually
- URLTest outbound wraps same protocols: auto-select by latency
- Selector contains URLTest ("Auto") plus individual servers
- Hierarchy: `Selector["Auto", "Server-1", "Server-2"]` where `Auto = URLTest["Server-1", "Server-2"]`

**Our current state:** We do exactly this already in `singbox.rs`. Good.

**What we're missing:**
- No CDN fallback outbound (VLESS-WS-CDN) in the selector group
- No Hysteria2 relay variants
- Hardcoded Hysteria2 credentials in backend code (security issue)

### 2.2 CDN Fallback (VLESS WebSocket through Cloudflare)

**How it works in production:**
```json
{
  "type": "vless",
  "tag": "CDN-Fallback",
  "server": "104.16.0.0",  // Cloudflare IP (or domain)
  "server_port": 443,
  "uuid": "<user-uuid>",
  "tls": {
    "enabled": true,
    "server_name": "your-domain.com"
  },
  "transport": {
    "type": "ws",
    "path": "/secret-path",
    "headers": {"Host": "your-domain.com"}
  }
}
```

**Key points:**
- Server address = Cloudflare IP (not origin server IP)
- TLS server_name = your domain proxied through CF
- WebSocket transport with secret path
- If origin IP gets blocked, CDN path still works
- Should be included in URLTest but with lower priority (higher tolerance)

**ACTION:** Add VLESS-WS-CDN outbound to config generator. Include in selector but NOT in URLTest (CDN has higher latency, use only as manual fallback).

### 2.3 Smart DNS Configuration

**Best practice from research (3-tier DNS):**

```json
{
  "dns": {
    "servers": [
      {"tag": "dns-remote", "address": "https://1.1.1.1/dns-query", "detour": "Proxy"},
      {"tag": "dns-direct", "address": "https://8.8.8.8/dns-query", "detour": "direct"},
      {"tag": "dns-block", "address": "rcode://refused"}
    ],
    "rules": [
      {"rule_set": ["geosite-ads"], "server": "dns-block"},
      {"outbound": "direct", "server": "dns-direct"},
      {"rule_set": ["geosite-ru-blocked"], "server": "dns-remote"}
    ],
    "final": "dns-remote"
  }
}
```

**Critical: DNS Bootstrap Loop Prevention**
- `dns-direct` must use plain IP or DoH with direct detour
- `dns-remote` detours through proxy
- `default_domain_resolver` resolves proxy server hostnames via direct DNS
- NEVER use DoH for direct DNS that resolves the proxy server itself

**Our current issue:** We use `https://8.8.8.8/dns-query` for dns-direct with detour "direct". This is correct but can be slow. Plain UDP `8.8.8.8` would be faster for bootstrap.

**ACTION:** 
1. Use plain `8.8.8.8` for `dns-direct` (faster bootstrap, no TLS overhead)
2. Keep DoH `https://1.1.1.1/dns-query` for `dns-remote` (encrypted, through proxy)
3. Add `dns-block` server for ad blocking (optional feature)

### 2.4 Multi-SNI Rotation

**Reality of SNI in 2025-2026 Russia:**
- Russia now uses SNI whitelist + CIDR-based blocking (not just blacklist)
- Simple SNI spoofing is less effective on mobile networks
- Mixed-case SNI (`wWw.bBc.cOM`) can bypass some DPI systems

**What Hiddify does:**
- TLS Tricks: fragment ClientHello packets, randomize SNI case, add padding
- These are per-connection settings, not "rotation" per se

**sing-box does NOT have native SNI rotation.** Each outbound has a fixed `server_name`. To rotate:
- Create multiple outbounds with different SNI values
- Wrap them in URLTest — blocked SNIs will fail health check and be deprioritized
- This is effectively "SNI rotation via health checking"

**ACTION:** Create multiple VLESS Reality outbounds per server with different SNI values. URLTest will automatically select the one that works:
```
Server-NL-SNI1 (server_name: "verified-sni-1.com")
Server-NL-SNI2 (server_name: "verified-sni-2.com")  
Server-NL-SNI3 (server_name: "verified-sni-3.com")
```

### 2.5 Server Selection UI

**sing-box-for-apple pattern:**
- `OutboundGroup` struct: `tag`, `type`, `selected`, `selectable`, `items[]`
- `OutboundGroupItem`: `tag`, `type`, `urlTestTime`, `urlTestDelay`
- Groups fetched via libbox gRPC `CommandClient`
- UI shows groups with latency badges ("123ms")
- Server switch = change selector default + reconnect

**Hiddify pattern:**
- Delay-based auto-selection (URLTest in sing-box)
- Manual override via selector
- Latency displayed per-node

**Our current state:** We have `ServerGroup` and `ServerItem` with similar structure. We parse from config JSON and also get live data via `CommandClient` gRPC. This is solid.

**What we're missing:**
- No latency testing initiated from the app (URLTest runs in the extension, but we don't show results)
- Server switch requires full reconnect (disconnect + reconnect). Hiddify/SFI use `reloadService()` for hot-reload.

**ACTION:**
1. Use `reloadService()` instead of disconnect+reconnect for server switching
2. Display URLTest latency results from gRPC in the server list

### 2.6 Fast Connection Establishment

**Techniques from research:**

1. **FakeIP DNS** — Assign fake IPs immediately, resolve real IPs lazily through proxy. Eliminates DNS resolution delay before connection. sing-box supports this natively:
   ```json
   {"tag": "dns-fake", "address": "fakeip", "strategy": "ipv4_only"}
   ```
   Requires `fakeip` config in DNS section with IP ranges.

2. **Config caching** — Keep last working config, connect immediately, update in background. We already do this.

3. **URLTest pre-warming** — sing-box runs URLTest on startup before first connection. Fastest node is pre-selected.

4. **Memory optimization** — iOS NetworkExtension limit is ~15MB. Go runtime takes ~5MB. Tips:
   - `LibboxSetMemoryLimit(true)` — we already call this
   - Minimize number of outbounds (each consumes memory)
   - Avoid WireGuard speedtest (causes memory spikes)

5. **TUN stack selection** — `"stack": "system"` is most compatible on iOS. `"mixed"` can be faster but less stable. We use `"system"` — correct choice.

6. **Reduce URLTest interval** — Our 300s (5min) is good. Default 180s (3min) is slightly aggressive for mobile.

**ACTION:**
1. Consider FakeIP for faster initial connections (advanced, test thoroughly)
2. Reduce outbound count where possible (merge redundant servers)

---

## 3. Recommended Config Architecture

Based on all research, here is the ideal sing-box config structure for Chameleon:

```json
{
  "log": {"level": "warning"},
  "dns": {
    "servers": [
      {"tag": "dns-remote", "address": "https://1.1.1.1/dns-query", "detour": "Proxy"},
      {"tag": "dns-direct", "address": "8.8.8.8", "detour": "direct"},
      {"tag": "dns-block", "address": "rcode://refused"}
    ],
    "rules": [
      {"outbound": "direct", "server": "dns-direct"}
    ],
    "final": "dns-remote"
  },
  "inbounds": [{
    "type": "tun",
    "tag": "tun-in",
    "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
    "auto_route": true,
    "stack": "system",
    "mtu": 1400
  }],
  "outbounds": [
    {
      "type": "selector",
      "tag": "Proxy",
      "outbounds": ["Auto", "NL-VLESS-TCP", "NL-VLESS-gRPC", "NL-HY2", "DE-VLESS-TCP", "CDN-Fallback"],
      "default": "Auto"
    },
    {
      "type": "urltest", 
      "tag": "Auto",
      "outbounds": ["NL-VLESS-TCP", "NL-VLESS-gRPC", "NL-HY2", "DE-VLESS-TCP"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "300s",
      "tolerance": 100,
      "interrupt_exist_connections": true
    },
    // ... individual server outbounds ...
    {
      "type": "vless",
      "tag": "CDN-Fallback",
      "server": "104.16.0.0",
      "server_port": 443,
      // ... VLESS-WS-CDN config (NOT in URLTest, manual fallback only)
    },
    {"type": "direct", "tag": "direct"}
  ],
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

**Key design decisions:**
1. CDN-Fallback in Selector but NOT in URLTest (high latency, emergency only)
2. URLTest with `tolerance: 100` and `interrupt_exist_connections: true`
3. Plain UDP DNS for direct (fast bootstrap)
4. DoH for remote DNS (encrypted, through proxy)
5. No FakeIP initially (add later after testing)

---

## 4. Priority Action Items

### P0 — Critical (Fix Current Issues)
1. **Fix DNS bootstrap:** Change `dns-direct` from DoH (`https://8.8.8.8/dns-query`) to plain UDP (`8.8.8.8`) for faster startup and to avoid TLS overhead on the direct path
2. **Hot-reload for server switch:** Use `reloadService()` instead of full disconnect+reconnect cycle when user changes server
3. **Remove hardcoded Hysteria2 credentials** from `singbox.rs` — load from DB/config

### P1 — High Priority (New Features)
4. **Add CDN fallback outbound:** Generate VLESS-WS-CDN outbound in `singbox.rs` for when direct IPs are blocked. Add to Selector but not URLTest
5. **Multiple SNI per server:** Create 2-3 outbounds per server with different verified SNIs. URLTest auto-selects working one
6. **Display latency in UI:** Read URLTest delay values from gRPC CommandClient and show in server list

### P2 — Medium Priority (Optimization)
7. **Add `interrupt_exist_connections: true`** to URLTest config for faster failover
8. **Add tolerance parameter** to URLTest (currently missing, defaults to 50ms)
9. **Russia rulesets integration:** Add route rules using `legiz-ru/sb-rule-sets` for selective proxying (only proxy blocked sites, direct for everything else)
10. **Ad-blocking DNS:** Add `dns-block` server with `rcode://refused` + adblock rule set

### P3 — Future (Advanced)
11. **FakeIP DNS** for zero-latency initial connections
12. **TLS fragmentation** options (Hiddify-style TLS tricks for DPI bypass)
13. **WARP integration** as additional fallback layer
14. **Config per-mode:** "Full proxy" vs "Smart" (only blocked sites) vs "Direct" modes

---

## 5. Reference Links

- [sing-box-for-apple](https://github.com/SagerNet/sing-box-for-apple) — Official iOS/macOS client
- [Hiddify App](https://github.com/hiddify/hiddify-app) — Most feature-rich open-source client
- [Hiddify sing-box fork](https://github.com/hiddify/hiddify-sing-box) — Extended sing-box with TLS tricks
- [Antizapret sing-box](https://github.com/savely-krasovsky/antizapret-sing-box) — Russia blocklist rulesets
- [legiz-ru/sb-rule-sets](https://github.com/legiz-ru/sb-rule-sets) — Russia-specific rule sets
- [sing-box DNS docs](https://sing-box.sagernet.org/configuration/dns/)
- [sing-box URLTest docs](https://sing-box.sagernet.org/configuration/outbound/urltest/)
- [sing-box Selector docs](https://sing-box.sagernet.org/configuration/outbound/selector/)
- [sing-box TLS docs](https://sing-box.sagernet.org/configuration/shared/tls/)
- [Recommended configs](https://gilbert.vicp.io/2024/03/23/Recommended-sing-box-Configurations/)
- [Russia bypass config](https://krasovs.ky/2024/08/05/sing-box-bypass.html)
- [Russia DPI discussion](https://github.com/net4people/bbs/issues/490)
- [Hiddify config architecture](https://deepwiki.com/hiddify/hiddify-app/4.1-configuration-options)
