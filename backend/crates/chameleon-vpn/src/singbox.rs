//! Sing-box config generator — produces JSON config for iOS/macOS native app.
//! Generates outbounds from ALL enabled protocols in the registry.

use serde_json::json;

use super::protocols::{
    ProtocolRegistry, ServerConfig, UserCredentials, OutboundOpts,
};

/// Generate a complete sing-box client config for a user.
pub fn generate_config(
    registry: &ProtocolRegistry,
    user: &UserCredentials,
    servers: &[ServerConfig],
) -> serde_json::Value {
    let mut outbounds = vec![];
    let mut tags = vec![];

    // ── Generate outbounds from ALL enabled protocols ──
    for proto in registry.enabled() {
        // Skip protocols that don't support sing-box (xdns, xicmp return None)
        let proto_name = proto.name();

        match proto_name {
            "vless_reality" => {
                // Generate per-server outbounds — only relay servers for iOS
                // Direct DE/NL IPs are blocked by RKN from Russia
                for srv in servers {
                    if !srv.key.starts_with("relay") { continue; }
                    let tag = format!("{} {}", srv.flag, srv.name);
                    let mut opts = OutboundOpts::default(); // TCP + Vision
                    // Per-server SNI override (e.g. NL uses different Reality dest than DE)
                    if !srv.sni.is_empty() {
                        opts.sni = Some(srv.sni.clone());
                    }
                    if let Some(ob) = proto.singbox_outbound(&tag, srv, user, &opts) {
                        tags.push(tag);
                        outbounds.push(ob);
                    }
                }
            }
            "vless_cdn" => {
                // CDN fallback — single outbound using Cloudflare domain
                let tag = "☁️ CDN Fallback".to_string();
                // Use first server as dummy — CDN ignores server host, uses its own domain
                if let Some(srv) = servers.first() {
                    if let Some(ob) = proto.singbox_outbound(&tag, srv, user, &OutboundOpts::default()) {
                        tags.push(tag);
                        outbounds.push(ob);
                    }
                }
            }
            "hysteria2" => {
                // Hysteria2 disabled in iOS config:
                // Direct server IPs blocked by RKN, UDP cannot go through TCP relay.
                // Causes urltest timeouts and degrades Auto selection.
                continue;
            }
            "warp" | "anytls" | "naiveproxy" => {
                // Single outbound per protocol
                let display = proto.display_name().to_string();
                if let Some(srv) = servers.first() {
                    let tag = format!("🔒 {}", display);
                    if let Some(ob) = proto.singbox_outbound(&tag, srv, user, &OutboundOpts::default()) {
                        tags.push(tag);
                        outbounds.push(ob);
                    }
                }
            }
            _ => {
                // xdns, xicmp — return None from singbox_outbound, skip
            }
        }
    }

    // ── Wrap in selector + urltest groups ──
    let mut all_outbounds = Vec::new();

    if tags.len() > 1 {
        all_outbounds.push(json!({
            "type": "selector",
            "tag": "Proxy",
            "outbounds": tags.iter().chain(std::iter::once(&"Auto".to_string())).collect::<Vec<_>>(),
            "default": "Auto",
        }));
        all_outbounds.push(json!({
            "type": "urltest",
            "tag": "Auto",
            "outbounds": &tags,
            "url": "https://www.gstatic.com/generate_204",
            "interval": "3m",
            "tolerance": 50,
        }));
    } else if tags.len() == 1 {
        all_outbounds.push(json!({
            "type": "selector",
            "tag": "Proxy",
            "outbounds": &tags,
            "default": &tags[0],
        }));
    }

    all_outbounds.extend(outbounds);
    all_outbounds.push(json!({"type": "direct", "tag": "direct"}));

    // ── DNS: FakeIP + bootstrap (no death loop) ──
    json!({
        "log": {"level": "warning"},
        "dns": {
            "servers": [
                {"tag": "dns-fake", "address": "fakeip"},
                {"tag": "dns-remote", "address": "1.1.1.1", "address_strategy": "ipv4_only", "detour": "Proxy"},
                {"tag": "dns-direct", "address": "8.8.8.8", "address_strategy": "ipv4_only", "detour": "direct"},
            ],
            "rules": [
                {"outbound": "any", "server": "dns-fake"},
                {"outbound": "direct", "server": "dns-direct"},
            ],
            "fakeip": {
                "enabled": true,
                "inet4_range": "198.18.0.0/15",
            },
            "final": "dns-remote",
            "independent_cache": true,
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30"],
                "auto_route": true,
                "stack": "system",
                "mtu": 1400,
            }
        ],
        "outbounds": all_outbounds,
        "route": {
            "default_domain_resolver": {"server": "dns-direct", "strategy": "ipv4_only"},
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"network": "udp", "port": 443, "action": "reject"},
                {"ip_is_private": true, "outbound": "direct"},
            ],
        },
    })
}
