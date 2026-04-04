//! VLESS WebSocket CDN — Cloudflare-proxied fallback.

use serde_json::json;
use chameleon_config::Settings;
use super::types::*;

const WS_PATH: &str = "/vless-ws";

pub struct VlessCdn {
    port: u16,
    domain: String,
}

impl VlessCdn {
    pub fn new(s: &Settings) -> Self {
        Self { port: s.vless_ws_port, domain: s.cdn_domain.clone() }
    }
}

impl Protocol for VlessCdn {
    fn name(&self) -> &str { "vless_cdn" }
    fn display_name(&self) -> &str { "VLESS CDN" }
    fn port(&self) -> u16 { self.port }

    fn xray_inbounds(&self, users: &[UserCredentials], _short_ids: &[String]) -> Vec<XrayInbound> {
        let clients: Vec<_> = users.iter().map(|u| json!({"id": u.uuid, "email": format!("{}@ws", u.username)})).collect();
        vec![XrayInbound {
            tag: "VLESS WS CDN".into(), port: self.port, protocol: "vless".into(),
            settings: json!({"clients": clients, "decryption": "none"}),
            stream_settings: json!({"network": "ws", "wsSettings": {"path": WS_PATH}}),
            sniffing: json!({"enabled": true, "destOverride": ["http", "tls"]}),
            listen: "127.0.0.1".into(),
        }]
    }

    fn node_inbounds(&self, _users: &[UserCredentials], _short_ids: &[String]) -> Vec<XrayInbound> {
        vec![] // CDN only on master
    }

    fn client_links(&self, user: &UserCredentials, _servers: &[ServerConfig]) -> Vec<ClientLink> {
        if self.domain.is_empty() { return vec![]; }
        let uri = format!(
            "vless://{}@{}:443?type=ws&security=tls&sni={}&host={}&path={}&fp=chrome#{}",
            user.uuid, self.domain, self.domain, self.domain,
            urlencoding::encode(WS_PATH), urlencoding::encode("CDN Fallback")
        );
        vec![ClientLink { uri, protocol: "vless".into(), transport: "ws".into(), server_key: "cdn".into(), remark: "CDN Fallback".into(), is_relay: false }]
    }

    fn singbox_outbound(&self, tag: &str, _server: &ServerConfig, user: &UserCredentials, _opts: &OutboundOpts) -> Option<serde_json::Value> {
        if self.domain.is_empty() { return None; }
        Some(json!({
            "type": "vless", "tag": tag, "server": self.domain, "server_port": 443, "uuid": user.uuid,
            "tls": {"enabled": true, "server_name": self.domain, "utls": {"enabled": true, "fingerprint": "chrome"}},
            "transport": {"type": "ws", "path": WS_PATH, "headers": {"Host": self.domain}},
            "multiplex": {"enabled": true, "protocol": "h2mux", "max_connections": 4, "padding": true},
        }))
    }
}
