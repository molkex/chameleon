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

    // Wrap proxy outbounds in a selector group for manual server switching
    // and a urltest group for automatic best-ping selection
    let mut all_outbounds = Vec::new();

    if tags.len() > 1 {
        // Selector: user picks server manually via gRPC/app UI
        all_outbounds.push(json!({
            "type": "selector",
            "tag": "Proxy",
            "outbounds": tags.iter().chain(std::iter::once(&"Auto".to_string())).collect::<Vec<_>>(),
            "default": "Auto",
        }));
        // URLTest: auto-select best ping
        all_outbounds.push(json!({
            "type": "urltest",
            "tag": "Auto",
            "outbounds": tags,
            "url": "https://www.gstatic.com/generate_204",
            "interval": "300s",
        }));
    } else if tags.len() == 1 {
        // Single server — no need for selector/urltest
        all_outbounds.push(json!({
            "type": "selector",
            "tag": "Proxy",
            "outbounds": &tags,
            "default": &tags[0],
        }));
    }

    all_outbounds.extend(outbounds); // actual proxy server outbounds

    // Hysteria2 outbound for high-speed connections (UDP/QUIC)
    let hy2_tag = "🚀 Fast (Hysteria2)".to_string();
    all_outbounds.push(json!({
        "type": "hysteria2",
        "tag": &hy2_tag,
        "server": "162.19.242.30",
        "server_port": 8443,
        "password": "ChameleonHy2-2026-Secure",
        "tls": {
            "enabled": true,
            "server_name": "ads.x5.ru",
            "insecure": true,
        },
    }));
    // Add Hysteria2 to selector and urltest
    if let Some(selector) = all_outbounds.first_mut() {
        if let Some(outs) = selector.get_mut("outbounds") {
            if let Some(arr) = outs.as_array_mut() {
                // Insert before "Auto"
                let auto_pos = arr.iter().position(|v| v.as_str() == Some("Auto")).unwrap_or(arr.len());
                arr.insert(auto_pos, json!(hy2_tag));
            }
        }
    }
    if let Some(urltest) = all_outbounds.get_mut(1) {
        if let Some(outs) = urltest.get_mut("outbounds") {
            if let Some(arr) = outs.as_array_mut() {
                arr.push(json!(hy2_tag));
            }
        }
    }

    all_outbounds.push(json!({"type": "direct", "tag": "direct"}));

    json!({
        "log": {"level": "warning"},
        "dns": {
            "servers": [
                {"tag": "dns-remote", "address": "https://1.1.1.1/dns-query", "detour": "Auto"},
                {"tag": "dns-direct", "address": "https://8.8.8.8/dns-query", "detour": "direct"},
            ],
            "rules": [
                {"outbound": "direct", "server": "dns-direct"},
            ],
            "final": "dns-remote",
            "strategy": "ipv4_only",
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
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
                {"ip_is_private": true, "outbound": "direct"},
            ],
        },
    })
}
