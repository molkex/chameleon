//! XDNS Tunnel — emergency fallback: proxy traffic over DNS queries.

use serde_json::json;
use chameleon_config::Settings;
use super::types::*;

pub struct Xdns {
    domain: String,
    is_enabled: bool,
}

impl Xdns {
    pub fn new(s: &Settings) -> Self {
        Self { domain: s.xdns_domain.clone(), is_enabled: s.xdns_enabled }
    }
}

impl Protocol for Xdns {
    fn name(&self) -> &str { "xdns" }
    fn display_name(&self) -> &str { "DNS Tunnel (Emergency)" }
    fn enabled(&self) -> bool { self.is_enabled && !self.domain.is_empty() }

    fn xray_inbounds(&self, _: &[UserCredentials], _: &[String]) -> Vec<XrayInbound> {
        if !self.enabled() { return vec![]; }
        vec![XrayInbound {
            tag: "xdns-in".into(), port: 53, protocol: "dokodemo-door".into(),
            settings: json!({"network": "udp", "followRedirect": false}),
            stream_settings: json!({"finalmask": {"type": "xdns"}}),
            sniffing: json!({"enabled": true, "destOverride": ["http", "tls"]}),
            listen: "0.0.0.0".into(),
        }]
    }

    fn xray_outbounds(&self) -> Vec<serde_json::Value> {
        if !self.enabled() { return vec![]; }
        vec![json!({"protocol": "freedom", "tag": "xdns-out", "streamSettings": {"finalmask": {"type": "xdns"}}})]
    }

    fn xray_routing_rules(&self) -> Vec<serde_json::Value> {
        if !self.enabled() { return vec![]; }
        vec![json!({"type": "field", "inboundTag": ["xdns-in"], "outboundTag": "xdns-out"})]
    }

    fn client_links(&self, user: &UserCredentials, servers: &[ServerConfig]) -> Vec<ClientLink> {
        if !self.enabled() { return vec![]; }
        servers.iter().map(|srv| {
            let remark = srv.remark("DNS-Tunnel");
            let uri = format!("xdns://{}@{}:53?domain={}&security=none#{}", user.uuid, self.domain, self.domain, remark);
            ClientLink { uri, protocol: "xdns".into(), transport: "dns".into(), server_key: srv.key.clone(), remark, is_relay: false }
        }).collect()
    }

    fn singbox_outbound(&self, _: &str, _: &ServerConfig, _: &UserCredentials, _: &OutboundOpts) -> Option<serde_json::Value> {
        None // Not supported by sing-box
    }
}
