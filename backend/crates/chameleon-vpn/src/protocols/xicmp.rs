//! XICMP Tunnel — emergency fallback: proxy traffic over ICMP ping packets.

use serde_json::json;
use chameleon_config::Settings;
use super::types::*;

pub struct Xicmp {
    is_enabled: bool,
}

impl Xicmp {
    pub fn new(s: &Settings) -> Self {
        Self { is_enabled: s.xicmp_enabled }
    }
}

impl Protocol for Xicmp {
    fn name(&self) -> &str { "xicmp" }
    fn display_name(&self) -> &str { "ICMP Tunnel (Emergency)" }
    fn enabled(&self) -> bool { self.is_enabled }

    fn xray_inbounds(&self, _: &[UserCredentials], _: &[String]) -> Vec<XrayInbound> {
        if !self.enabled() { return vec![]; }
        vec![XrayInbound {
            tag: "xicmp-in".into(), port: 0, protocol: "dokodemo-door".into(),
            settings: json!({"network": "tcp,udp", "followRedirect": false}),
            stream_settings: json!({"network": "mkcp", "kcpSettings": {"header": {"type": "none"}, "seed": ""}, "finalmask": {"type": "xicmp"}}),
            sniffing: json!({"enabled": true, "destOverride": ["http", "tls"]}),
            listen: "0.0.0.0".into(),
        }]
    }

    fn xray_outbounds(&self) -> Vec<serde_json::Value> {
        if !self.enabled() { return vec![]; }
        vec![json!({"protocol": "freedom", "tag": "xicmp-out", "streamSettings": {"finalmask": {"type": "xicmp"}}})]
    }

    fn xray_routing_rules(&self) -> Vec<serde_json::Value> {
        if !self.enabled() { return vec![]; }
        vec![json!({"type": "field", "inboundTag": ["xicmp-in"], "outboundTag": "xicmp-out"})]
    }

    fn client_links(&self, user: &UserCredentials, servers: &[ServerConfig]) -> Vec<ClientLink> {
        if !self.enabled() { return vec![]; }
        servers.iter().map(|srv| {
            let remark = format!("{} {} ICMP-Tunnel", srv.flag, srv.name);
            let uri = format!("xicmp://{}@{}?transport=mkcp&security=none#{}", user.uuid, srv.host, remark);
            ClientLink { uri, protocol: "xicmp".into(), transport: "icmp".into(), server_key: srv.key.clone(), remark, is_relay: false }
        }).collect()
    }

    fn singbox_outbound(&self, _: &str, _: &ServerConfig, _: &UserCredentials, _: &OutboundOpts) -> Option<serde_json::Value> {
        None // Not supported by sing-box
    }
}
