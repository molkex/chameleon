//! Sing-box config generator — produces JSON config for iOS/macOS native app.
//! Called by the mobile /config endpoint.

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
    let mut selector_tags = vec![];

    // Generate outbounds from each enabled protocol + server
    for proto in registry.enabled() {
        for srv in servers {
            let tag = format!("{} {} {}", srv.flag, srv.name, proto.display_name());
            let opts = OutboundOpts::default();

            if let Some(outbound) = proto.singbox_outbound(&tag, srv, user, &opts) {
                selector_tags.push(tag.clone());
                outbounds.push(outbound);
            }

            // VLESS Reality — also add XHTTP variant
            if proto.name() == "vless_reality" {
                let xhttp_tag = format!("{} {} XHTTP", srv.flag, srv.name);
                let xhttp_opts = OutboundOpts { transport: Some("xhttp".into()), ..Default::default() };
                if let Some(ob) = proto.singbox_outbound(&xhttp_tag, srv, user, &xhttp_opts) {
                    selector_tags.push(xhttp_tag);
                    outbounds.push(ob);
                }
            }
        }
    }

    // Auto selector (uses first available)
    let auto_tag = "Auto".to_string();
    outbounds.push(json!({
        "type": "urltest",
        "tag": auto_tag,
        "outbounds": selector_tags,
        "url": "https://www.gstatic.com/generate_204",
        "interval": "3m",
        "tolerance": 100,
    }));

    // Main selector
    let mut main_outbounds = vec![auto_tag.clone()];
    main_outbounds.extend(selector_tags.clone());
    outbounds.push(json!({
        "type": "selector",
        "tag": "Proxy",
        "outbounds": main_outbounds,
        "default": auto_tag,
    }));

    // Direct + Block
    outbounds.push(json!({"type": "direct", "tag": "Direct"}));
    outbounds.push(json!({"type": "block", "tag": "Block"}));

    // Build full config (sing-box 1.13 format)
    json!({
        "log": {"level": "info"},
        "dns": {
            "servers": [
                {"tag": "proxy-dns", "address": "https://1.1.1.1/dns-query", "detour": "Proxy"},
                {"tag": "direct-dns", "address": "https://dns.google/dns-query", "detour": "Direct"},
            ],
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "auto_route": true,
                "stack": "mixed",
            }
        ],
        "outbounds": outbounds,
        "route": {
            "default_domain_resolver": {"server": "direct-dns", "strategy": "ipv4_only"},
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"ip_is_private": true, "outbound": "Direct"},
            ],
        },
        "experimental": {
            "cache_file": {"enabled": true},
        },
    })
}
