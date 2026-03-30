//! AnyTLS — defeats TLS-in-TLS fingerprinting.

use serde_json::json;
use chameleon_config::Settings;
use super::types::*;

pub struct AnyTls {
    port: u16,
    password: String,
    sni: String,
}

impl AnyTls {
    pub fn new(s: &Settings) -> Self {
        Self { port: s.anytls_port, password: s.anytls_password.clone(), sni: s.anytls_sni.clone() }
    }
}

impl Protocol for AnyTls {
    fn name(&self) -> &str { "anytls" }
    fn display_name(&self) -> &str { "AnyTLS" }
    fn enabled(&self) -> bool { !self.password.is_empty() }
    fn xray_inbounds(&self, _: &[UserCredentials], _: &[String]) -> Vec<XrayInbound> { vec![] }

    fn client_links(&self, _user: &UserCredentials, servers: &[ServerConfig]) -> Vec<ClientLink> {
        servers.iter().map(|srv| {
            let host = srv.effective_host();
            let remark = srv.remark("AnyTLS");
            let uri = format!("anytls://{}@{}:{}?sni={}#{}", self.password, host, self.port, self.sni, urlencoding::encode(&remark));
            ClientLink { uri, protocol: "anytls".into(), transport: "tcp".into(), server_key: srv.key.clone(), remark, is_relay: false }
        }).collect()
    }

    fn singbox_outbound(&self, tag: &str, server: &ServerConfig, _user: &UserCredentials, _opts: &OutboundOpts) -> Option<serde_json::Value> {
        if self.password.is_empty() { return None; }
        let host = server.effective_host();
        Some(json!({
            "type": "anytls", "tag": tag, "server": host, "server_port": self.port,
            "password": self.password, "idle_timeout": "15m",
            "tls": {"enabled": true, "server_name": self.sni},
        }))
    }
}
