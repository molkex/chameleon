//! Hysteria2 — UDP protocol with FinalMask obfuscation.

use serde_json::json;
use chameleon_config::Settings;
use super::types::*;

pub struct Hysteria2 {
    password: String,
    obfs_password: String,
    port: u16,
    sni: String,
    finalmask_mode: String,
}

impl Hysteria2 {
    pub fn new(s: &Settings) -> Self {
        Self {
            password: s.hy2_password.clone(),
            obfs_password: s.hy2_obfs_password.clone(),
            port: s.hysteria2_port,
            sni: s.hy2_sni.clone(),
            finalmask_mode: s.finalmask_mode.clone(),
        }
    }
}

impl Protocol for Hysteria2 {
    fn name(&self) -> &str { "hysteria2" }
    fn display_name(&self) -> &str { "Hysteria2" }
    fn enabled(&self) -> bool { !self.password.is_empty() }

    fn xray_inbounds(&self, _users: &[UserCredentials], _short_ids: &[String]) -> Vec<XrayInbound> {
        vec![] // Separate binary
    }

    fn xray_outbounds(&self) -> Vec<serde_json::Value> {
        if !matches!(self.finalmask_mode.as_str(), "xdns" | "xicmp") { return vec![]; }
        vec![json!({"protocol": "freedom", "tag": "hy2-finalmask", "streamSettings": {"finalmask": {"type": self.finalmask_mode}}})]
    }

    fn xray_routing_rules(&self) -> Vec<serde_json::Value> {
        if !matches!(self.finalmask_mode.as_str(), "xdns" | "xicmp") { return vec![]; }
        vec![json!({"type": "field", "inboundTag": ["hy2-in"], "outboundTag": "hy2-finalmask"})]
    }

    fn client_links(&self, _user: &UserCredentials, servers: &[ServerConfig]) -> Vec<ClientLink> {
        if self.password.is_empty() { return vec![]; }
        servers.iter().map(|srv| {
            let remark = format!("{} {} Hysteria2", srv.flag, srv.name);
            let uri = format!(
                "hy2://{}@{}:{}?insecure=1&sni={}&obfs=salamander&obfs-password={}#{}",
                self.password, srv.host, self.port, self.sni, self.obfs_password, urlencoding::encode(&remark)
            );
            ClientLink { uri, protocol: "hysteria2".into(), transport: "udp".into(), server_key: srv.key.clone(), remark, is_relay: false }
        }).collect()
    }

    fn singbox_outbound(&self, tag: &str, server: &ServerConfig, _user: &UserCredentials, _opts: &OutboundOpts) -> Option<serde_json::Value> {
        if self.password.is_empty() { return None; }
        Some(json!({
            "type": "hysteria2", "tag": tag, "server": server.host, "server_port": self.port,
            "password": self.password,
            "tls": {"enabled": true, "server_name": self.sni, "insecure": true},
            "obfs": {"type": "salamander", "password": self.obfs_password},
        }))
    }
}
