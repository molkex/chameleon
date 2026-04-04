//! VLESS Reality — TCP (Vision flow) + XHTTP + gRPC inbounds.

use sha2::{Sha256, Digest};
use serde_json::json;

use chameleon_config::Settings;
use super::types::*;

const FINGERPRINT: &str = "chrome";

pub struct VlessReality {
    private_key: String,
    public_key: String,
    snis: Vec<String>,
    dest: String,
    tcp_port: u16,
    grpc_port: u16,
    relays: String, // raw JSON from config
}

impl VlessReality {
    pub fn new(s: &Settings) -> Self {
        let snis = if s.reality_snis.is_empty() { vec!["ads.x5.ru".into()] } else { s.reality_snis.clone() };
        let dest = format!("{}:443", snis[0]);
        Self {
            private_key: s.reality_private_key.clone(),
            public_key: s.reality_public_key.clone(),
            snis,
            dest,
            tcp_port: s.vless_tcp_port,
            grpc_port: s.vless_grpc_port,
            relays: s.relay_servers_raw.clone(),
        }
    }

    fn reality_settings(&self, short_ids: &[String]) -> serde_json::Value {
        let mut ids: Vec<String> = short_ids.to_vec();
        if !ids.contains(&String::new()) { ids.push(String::new()); }
        ids.sort();
        ids.dedup();
        json!({
            "show": false,
            "dest": self.dest,
            "xver": 0,
            "serverNames": self.snis,
            "privateKey": self.private_key,
            "shortIds": ids,
            "echForceQuery": "full",
        })
    }

    fn make_inbound(&self, tag: &str, port: u16, network: &str, clients: Vec<serde_json::Value>, short_ids: &[String]) -> XrayInbound {
        let mut stream = json!({
            "network": network,
            "security": "reality",
            "realitySettings": self.reality_settings(short_ids),
        });
        match network {
            "tcp" => { stream["sockopt"] = json!({"tcpFastOpen": true}); }
            "grpc" => { stream["grpcSettings"] = json!({"serviceName": ""}); }
            "xhttp" => { stream["xhttpSettings"] = json!({"mode": "auto", "browserMasquerading": "chrome"}); }
            _ => {}
        }

        let mut settings = json!({"clients": clients, "decryption": "none"});
        if network == "tcp" {
            settings["fallbacks"] = json!([]);
        }

        XrayInbound {
            tag: tag.to_string(),
            port,
            protocol: "vless".to_string(),
            settings,
            stream_settings: stream,
            sniffing: json!({"enabled": true, "destOverride": ["http", "tls"]}),
            listen: "0.0.0.0".to_string(),
        }
    }

    fn build_clients(&self, users: &[UserCredentials], suffix: &str, flow: &str) -> Vec<serde_json::Value> {
        users.iter().map(|u| {
            let mut c = json!({"id": u.uuid, "email": format!("{}@{}", u.username, suffix)});
            if !flow.is_empty() { c["flow"] = json!(flow); }
            c
        }).collect()
    }

    fn get_user_snis(&self, username: &str, count: usize) -> Vec<String> {
        if self.snis.is_empty() { return vec![]; }
        let hash = Sha256::digest(username.as_bytes());
        let offset = (hash[0] as usize) % self.snis.len();
        let mut rotated: Vec<String> = self.snis[offset..].iter().chain(self.snis[..offset].iter()).cloned().collect();
        rotated.truncate(count);
        rotated
    }

    fn tcp_link(&self, user: &UserCredentials, host: &str, port: u16, sni: &str, remark: &str, server_key: &str, is_relay: bool) -> ClientLink {
        let uri = format!(
            "vless://{}@{}:{}?type=tcp&security=reality&sni={}&fp={}&pbk={}&sid={}&flow=xtls-rprx-vision#{}",
            user.uuid, host, port, sni, FINGERPRINT, self.public_key, user.short_id, urlencoding::encode(remark)
        );
        ClientLink { uri, protocol: "vless".into(), transport: "tcp".into(), server_key: server_key.into(), remark: remark.into(), is_relay }
    }

    fn grpc_link(&self, user: &UserCredentials, host: &str, port: u16, sni: &str, remark: &str, server_key: &str, is_relay: bool) -> ClientLink {
        let uri = format!(
            "vless://{}@{}:{}?type=grpc&security=reality&sni={}&fp={}&pbk={}&sid={}&serviceName=&authority=&encryption=none#{}",
            user.uuid, host, port, sni, FINGERPRINT, self.public_key, user.short_id, urlencoding::encode(remark)
        );
        ClientLink { uri, protocol: "vless".into(), transport: "grpc".into(), server_key: server_key.into(), remark: remark.into(), is_relay }
    }
}

impl Protocol for VlessReality {
    fn name(&self) -> &str { "vless_reality" }
    fn display_name(&self) -> &str { "VLESS Reality" }
    fn port(&self) -> u16 { self.tcp_port }

    fn xray_inbounds(&self, users: &[UserCredentials], short_ids: &[String]) -> Vec<XrayInbound> {
        let tcp = self.build_clients(users, "xray", "xtls-rprx-vision");
        let xhttp = self.build_clients(users, "xhttp", "");
        let grpc = self.build_clients(users, "grpc", "");
        vec![
            self.make_inbound("VLESS TCP REALITY", self.tcp_port, "tcp", tcp, short_ids),
            self.make_inbound("VLESS XHTTP REALITY", 2097, "xhttp", xhttp, short_ids),
            self.make_inbound("VLESS gRPC REALITY", self.grpc_port, "grpc", grpc, short_ids),
        ]
    }

    fn client_links(&self, user: &UserCredentials, servers: &[ServerConfig]) -> Vec<ClientLink> {
        let mut links = vec![];
        let user_snis = self.get_user_snis(&user.username, 5);
        let default_sni = user_snis.first().map(|s| s.as_str()).unwrap_or("ads.x5.ru");

        for srv in servers {
            let host = srv.effective_host();
            let base = format!("{} {}", srv.flag, srv.name);
            for sni in &user_snis {
                let sni_label = sni.split('.').next().unwrap_or(sni);
                links.push(self.tcp_link(user, host, self.tcp_port, sni, &format!("{base} [{sni_label}]"), &srv.key, false));
            }
            links.push(self.grpc_link(user, host, self.grpc_port, default_sni, &format!("{base} gRPC"), &srv.key, false));
        }
        links
    }

    fn singbox_outbound(&self, tag: &str, server: &ServerConfig, user: &UserCredentials, opts: &OutboundOpts) -> Option<serde_json::Value> {
        let transport = opts.transport.as_deref().unwrap_or("tcp");
        let sni = opts.sni.as_deref().unwrap_or_else(|| self.snis.first().map(|s| s.as_str()).unwrap_or("ads.x5.ru"));
        let host = server.effective_host();
        let port = if transport == "tcp" { self.tcp_port } else { self.grpc_port };

        let mut out = json!({
            "type": "vless",
            "tag": tag,
            "server": host,
            "server_port": port,
            "uuid": user.uuid,
            "tls": {
                "enabled": true,
                "server_name": sni,
                "utls": {"enabled": true, "fingerprint": FINGERPRINT},
                "reality": {"enabled": true, "public_key": self.public_key, "short_id": user.short_id},
            },
        });
        if transport == "tcp" {
            // flow and multiplex are mutually exclusive in sing-box — Vision operates at TLS layer
            out["flow"] = json!("xtls-rprx-vision");
        } else if transport == "grpc" {
            out["transport"] = json!({"type": "grpc", "service_name": ""});
            // gRPC has built-in multiplexing, adding h2mux on top causes issues
        }
        Some(out)
    }
}
