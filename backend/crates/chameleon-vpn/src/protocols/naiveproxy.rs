//! NaiveProxy — real Chromium networking stack, unfingerprintable.

use serde_json::json;
use chameleon_config::Settings;
use super::types::*;

pub struct NaiveProxy {
    port: u16,
    username: String,
    password: String,
    domain: String,
}

impl NaiveProxy {
    pub fn new(s: &Settings) -> Self {
        Self { port: s.naive_port, username: s.naive_username.clone(), password: s.naive_password.clone(), domain: s.naive_domain.clone() }
    }
}

impl Protocol for NaiveProxy {
    fn name(&self) -> &str { "naiveproxy" }
    fn display_name(&self) -> &str { "NaiveProxy" }
    fn enabled(&self) -> bool { !self.password.is_empty() }
    fn xray_inbounds(&self, _: &[UserCredentials], _: &[String]) -> Vec<XrayInbound> { vec![] }

    fn client_links(&self, _user: &UserCredentials, servers: &[ServerConfig]) -> Vec<ClientLink> {
        servers.iter().map(|srv| {
            let domain = srv.resolve_host(&self.domain);
            let remark = srv.remark("Naive");
            let uri = format!("naive+https://{}:{}@{}:{}#{}", self.username, self.password, domain, self.port, urlencoding::encode(&remark));
            ClientLink { uri, protocol: "naive".into(), transport: "h2".into(), server_key: srv.key.clone(), remark, is_relay: false }
        }).collect()
    }

    fn singbox_outbound(&self, tag: &str, server: &ServerConfig, _user: &UserCredentials, opts: &OutboundOpts) -> Option<serde_json::Value> {
        if self.password.is_empty() { return None; }
        let domain = server.resolve_host(&self.domain);
        let network = opts.network.as_deref().unwrap_or("h2");
        Some(json!({
            "type": "naive", "tag": tag, "server": domain, "server_port": self.port,
            "username": self.username, "password": self.password, "network": network,
            "tls": {"enabled": true, "server_name": domain},
        }))
    }
}
