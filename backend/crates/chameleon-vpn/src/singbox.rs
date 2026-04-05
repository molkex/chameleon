//! Sing-box config generator — produces JSON config for iOS/macOS native app.

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

    // Generate one VLESS Reality TCP outbound per server
    for proto in registry.enabled() {
        if proto.name() != "vless_reality" { continue; }
        for srv in servers {
            let tag = format!("{} {}", srv.flag, srv.name);
            let opts = OutboundOpts::default(); // TCP
            if let Some(ob) = proto.singbox_outbound(&tag, srv, user, &opts) {
                tags.push(tag);
                outbounds.push(ob);
            }
        }
    }

    // Build outbounds: direct first (default), then proxy servers
    let mut all_outbounds = vec![
        json!({"type": "direct", "tag": "direct"}),
    ];
    all_outbounds.extend(outbounds);

    // If no servers, still return a valid config
    let proxy_tag = tags.first().cloned().unwrap_or_else(|| "direct".to_string());

    json!({
        "log": {"level": "debug"},
        "dns": {
            "servers": [
                {"tag": "dns-direct", "address": "8.8.8.8"},
            ],
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "auto_route": true,
                "stack": "system",
            }
        ],
        "outbounds": all_outbounds,
        "route": {
            "default_domain_resolver": {"server": "dns-direct", "strategy": "ipv4_only"},
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"ip_is_private": true, "outbound": "direct"},
            ],
            "final": proxy_tag,
        },
    })
}
