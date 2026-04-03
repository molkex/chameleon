//! WARP+ WireGuard — outbound-only routing for blocked domains via Cloudflare.

use serde_json::json;
use chameleon_config::Settings;
use super::types::*;

const WARP_PEER_PUBKEY: &str = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=";

pub struct Warp {
    private_key: String,
    address_v4: String,
    address_v6: String,
    endpoint: String,
    reserved: Vec<i32>,
    finalmask_mode: String,
    domains: Vec<String>,
}

impl Warp {
    pub fn new(s: &Settings) -> Self {
        Self {
            private_key: s.warp_private_key.clone(),
            address_v4: s.warp_address_v4.clone(),
            address_v6: s.warp_address_v6.clone(),
            endpoint: s.warp_endpoint.clone(),
            reserved: s.warp_reserved.clone(),
            finalmask_mode: s.finalmask_mode.clone(),
            domains: s.warp_domains.clone(),
        }
    }

    fn parse_endpoint(&self) -> (&str, u16) {
        match self.endpoint.rsplit_once(':') {
            Some((host, port)) => (host, port.parse().unwrap_or(2408)),
            None => (self.endpoint.as_str(), 2408),
        }
    }
}

impl Protocol for Warp {
    fn name(&self) -> &str { "warp" }
    fn display_name(&self) -> &str { "WARP+" }
    fn enabled(&self) -> bool { !self.private_key.is_empty() }

    fn xray_inbounds(&self, _users: &[UserCredentials], _short_ids: &[String]) -> Vec<XrayInbound> { vec![] }

    fn xray_outbounds(&self) -> Vec<serde_json::Value> {
        if self.private_key.is_empty() {
            return vec![json!({"protocol": "blackhole", "tag": "WARP"})];
        }
        let (host, port) = self.parse_endpoint();
        let endpoint = format!("{host}:{port}");
        let mut addresses = vec![json!(self.address_v4)];
        if !self.address_v6.is_empty() { addresses.push(json!(self.address_v6)); }

        let mut outbound = json!({
            "tag": "WARP", "protocol": "wireguard",
            "settings": {
                "secretKey": self.private_key, "address": addresses,
                "peers": [{"publicKey": WARP_PEER_PUBKEY, "allowedIPs": ["0.0.0.0/0", "::/0"], "endpoint": endpoint}],
                "reserved": self.reserved, "mtu": 1280, "domainStrategy": "ForceIP",
            },
        });
        if self.finalmask_mode != "off" {
            outbound["streamSettings"] = json!({"finalmask": {"type": self.finalmask_mode}});
        }
        vec![outbound]
    }

    fn xray_routing_rules(&self) -> Vec<serde_json::Value> {
        if self.private_key.is_empty() { return vec![]; }
        if self.domains.is_empty() {
            // No domains configured — route all traffic through WARP (default route)
            vec![json!({"type": "field", "network": "tcp,udp", "outboundTag": "WARP"})]
        } else {
            vec![json!({"type": "field", "domain": self.domains, "outboundTag": "WARP"})]
        }
    }

    fn client_links(&self, _user: &UserCredentials, _servers: &[ServerConfig]) -> Vec<ClientLink> { vec![] }

    fn singbox_outbound(&self, tag: &str, _server: &ServerConfig, _user: &UserCredentials, _opts: &OutboundOpts) -> Option<serde_json::Value> {
        if self.private_key.is_empty() { return None; }
        let (host, port) = self.parse_endpoint();
        let mut local = vec![json!(self.address_v4)];
        if !self.address_v6.is_empty() { local.push(json!(self.address_v6)); }
        Some(json!({
            "type": "wireguard", "tag": tag, "private_key": self.private_key,
            "local_address": local, "peer_public_key": WARP_PEER_PUBKEY,
            "server": host, "server_port": port, "reserved": self.reserved, "mtu": 1280,
        }))
    }
}
