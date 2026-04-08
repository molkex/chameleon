//! ChameleonEngine — stateless VPN orchestrator.
//! All state lives in PostgreSQL and Redis. No in-process caches.

use std::path::PathBuf;
use serde_json::json;
use sqlx::PgPool;
use tokio::process::Command;
use tracing::{info, warn, error};

use chameleon_config::Settings;
use super::protocols::{ProtocolRegistry, ServerConfig, UserCredentials, XrayInbound};
use super::xray_api::XrayApi;

pub struct ChameleonEngine {
    settings: Settings,
    xray_config_dir: PathBuf,
    xray_config_path: PathBuf,
    singbox_config_path: PathBuf,
    xray_api: XrayApi,
    registry: ProtocolRegistry,
}

impl ChameleonEngine {
    pub fn new(settings: &Settings) -> Result<Self, String> {
        let dir = std::env::var("XRAY_CONFIG_DIR").unwrap_or_else(|_| "/etc/xray".into());
        // gRPC address: XRAY_GRPC_ADDR env or default host:port
        let grpc_host = std::env::var("XRAY_GRPC_HOST").unwrap_or_else(|_| "xray".into());
        let grpc_addr = format!("{}:{}", grpc_host, settings.xray_stats_port);

        Ok(Self {
            xray_config_path: PathBuf::from(&dir).join("config.json"),
            singbox_config_path: PathBuf::from(&dir).join("singbox-config.json"),
            xray_config_dir: PathBuf::from(&dir),
            xray_api: XrayApi::new(&grpc_addr),
            registry: ProtocolRegistry::new(settings),
            settings: settings.clone(),
        })
    }

    pub fn registry(&self) -> &ProtocolRegistry {
        &self.registry
    }

    pub fn xray_api(&self) -> &XrayApi {
        &self.xray_api
    }

    /// Full config generation on startup.
    pub async fn init(&self, pool: &PgPool) {
        let active = load_active_users(pool).await;
        info!(users = active.len(), "ChameleonEngine: loaded active users");

        if self.xray_config_dir.is_dir() || std::env::var("XRAY_MANAGED").is_ok() {
            let config = self.build_master_config(&active);
            if let Err(e) = std::fs::create_dir_all(&self.xray_config_dir) {
                error!(error = %e, "Failed to create xray config dir");
                return;
            }
            match std::fs::write(&self.xray_config_path, serde_json::to_string_pretty(&config).unwrap_or_default()) {
                Ok(_) => info!(path = %self.xray_config_path.display(), "Initial xray config written"),
                Err(e) => error!(error = %e, "Failed to write xray config"),
            }

            // Write sing-box server config for MUX
            let sb_config = self.build_singbox_server_config(&active);
            match std::fs::write(&self.singbox_config_path, serde_json::to_string_pretty(&sb_config).unwrap_or_default()) {
                Ok(_) => info!(path = %self.singbox_config_path.display(), "sing-box server config written"),
                Err(e) => error!(error = %e, "Failed to write sing-box server config"),
            }
        }

        if self.xray_api.health_check().await {
            info!("Xray health check passed");
        } else {
            warn!("Xray health check failed — gRPC API may be unavailable");
        }
    }

    /// Build full xray config for master server from protocol registry.
    pub fn build_master_config(&self, users: &[ActiveUser]) -> serde_json::Value {
        let (creds, short_ids) = to_credentials(users);
        let mut inbounds = vec![stats_api_inbound(self.settings.xray_stats_port)];
        let mut outbounds: Vec<serde_json::Value> = vec![];
        let mut routing_rules = vec![json!({"type": "field", "inboundTag": ["api"], "outboundTag": "api"})];

        for proto in self.registry.enabled() {
            for ib in proto.xray_inbounds(&creds, &short_ids) {
                inbounds.push(xray_inbound_to_json(&ib));
            }
            outbounds.extend(proto.xray_outbounds());
            routing_rules.extend(proto.xray_routing_rules());
        }

        ensure_default_outbounds(&mut outbounds);
        routing_rules.push(json!({"type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK"}));

        json!({
            "log": {"loglevel": "warning"},
            "stats": {},
            "api": {"tag": "api", "services": ["StatsService", "HandlerService"]},
            "policy": {
                "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}},
                "system": {"statsInboundUplink": true, "statsInboundDownlink": true,
                           "statsOutboundUplink": true, "statsOutboundDownlink": true},
            },
            "dns": {"servers": ["1.1.1.1", "8.8.8.8"], "queryStrategy": "UseIPv4"},
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": {"domainStrategy": "IPIfNonMatch", "domainMatcher": "mph", "rules": routing_rules},
        })
    }

    /// Build xray config for remote nodes.
    pub fn build_node_config(&self, users: &[ActiveUser]) -> serde_json::Value {
        let (creds, short_ids) = to_credentials(users);
        let mut inbounds = vec![];
        let mut outbounds: Vec<serde_json::Value> = vec![];
        let mut routing_rules = vec![];

        for proto in self.registry.with_inbounds() {
            for ib in proto.node_inbounds(&creds, &short_ids) {
                inbounds.push(xray_inbound_to_json(&ib));
            }
            outbounds.extend(proto.xray_outbounds());
            routing_rules.extend(proto.xray_routing_rules());
        }

        ensure_default_outbounds(&mut outbounds);
        routing_rules.push(json!({"type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK"}));

        json!({
            "log": {"loglevel": "warning"},
            "dns": {"servers": ["1.1.1.1", "8.8.8.8"], "queryStrategy": "UseIPv4"},
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": {"domainStrategy": "AsIs", "domainMatcher": "mph", "rules": routing_rules},
        })
    }

    /// Build sing-box server config for MUX support (port 2094).
    pub fn build_singbox_server_config(&self, users: &[ActiveUser]) -> serde_json::Value {
        let (creds, short_ids) = to_credentials(users);
        let sni = self.settings.reality_snis.first()
            .map(|s| s.as_str()).unwrap_or("ads.x5.ru");

        let sb_users: Vec<serde_json::Value> = creds.iter().map(|u| {
            json!({"name": &u.username, "uuid": &u.uuid})
        }).collect();

        json!({
            "log": {"level": "info"},
            "inbounds": [{
                "type": "vless",
                "tag": "vless-reality-mux",
                "listen": "0.0.0.0",
                "listen_port": 2094,
                "users": sb_users,
                "tls": {
                    "enabled": true,
                    "server_name": sni,
                    "reality": {
                        "enabled": true,
                        "handshake": {
                            "server": sni,
                            "server_port": 443
                        },
                        "private_key": &self.settings.reality_private_key,
                        "short_id": short_ids,
                    }
                },
                "multiplex": {
                    "enabled": true,
                    "padding": true,
                }
            }],
            "outbounds": [{
                "type": "direct",
                "tag": "direct",
            }],
            "route": {
                "default_domain_resolver": {"server": "dns-local", "strategy": "ipv4_only"},
            },
            "dns": {
                "servers": [{"tag": "dns-local", "type": "local"}],
            },
        })
    }

    /// Build server configs from settings (env fallback).
    pub fn build_server_configs(&self) -> Vec<ServerConfig> {
        Self::parse_server_configs_from_env(&self.settings.vpn_servers_raw, self.settings.vless_tcp_port)
    }

    /// Build server configs from DB rows. Falls back to env if DB list is empty.
    pub async fn build_server_configs_from_db(&self, pool: &PgPool) -> Vec<ServerConfig> {
        match chameleon_db::queries::servers::list_active(pool).await {
            Ok(db_servers) if !db_servers.is_empty() => {
                db_servers.iter().map(|s| ServerConfig {
                    host: s.host.clone(),
                    port: s.port as u16,
                    domain: s.domain.clone(),
                    flag: s.flag.clone(),
                    name: s.name.clone(),
                    key: s.key.clone(),
                    sni: s.sni.clone(),
                }).collect()
            }
            Ok(_) => {
                warn!("No active servers in DB — falling back to VPN_SERVERS env");
                self.build_server_configs()
            }
            Err(e) => {
                error!(error = %e, "Failed to load servers from DB — falling back to VPN_SERVERS env");
                self.build_server_configs()
            }
        }
    }

    /// Parse server configs from raw JSON env string.
    fn parse_server_configs_from_env(raw: &str, default_port: u16) -> Vec<ServerConfig> {
        let servers: Vec<serde_json::Value> = serde_json::from_str(raw).unwrap_or_default();
        servers.iter().filter_map(|srv| {
            let ip = srv.get("host").or_else(|| srv.get("ip"))?.as_str()?;
            let domain = srv.get("domain").and_then(|d| d.as_str()).unwrap_or(ip);
            let port = srv.get("port").and_then(|p| p.as_u64()).unwrap_or(default_port as u64) as u16;
            let key = srv.get("key").and_then(|k| k.as_str()).unwrap_or(domain.split('.').next().unwrap_or(domain));
            Some(ServerConfig {
                host: ip.to_string(),
                port,
                domain: domain.to_string(),
                flag: srv.get("flag").and_then(|f| f.as_str()).unwrap_or("").to_string(),
                name: srv.get("name").and_then(|n| n.as_str()).unwrap_or("").to_string(),
                key: key.to_string(),
                sni: srv.get("sni").and_then(|s| s.as_str()).unwrap_or("").to_string(),
            })
        }).collect()
    }

    /// Regenerate config file with current users (for xray restart resilience).
    pub async fn sync_config(&self, pool: &PgPool) {
        let active = load_active_users(pool).await;
        let config = self.build_master_config(&active);
        let _ = std::fs::create_dir_all(&self.xray_config_dir);
        match std::fs::write(&self.xray_config_path, serde_json::to_string_pretty(&config).unwrap_or_default()) {
            Ok(_) => info!(users = active.len(), "Xray config synced"),
            Err(e) => error!(error = %e, "Failed to write xray config"),
        }

        // Sync sing-box server config
        let sb_config = self.build_singbox_server_config(&active);
        match std::fs::write(&self.singbox_config_path, serde_json::to_string_pretty(&sb_config).unwrap_or_default()) {
            Ok(_) => info!("sing-box server config synced"),
            Err(e) => error!(error = %e, "Failed to write sing-box server config"),
        }
    }

    /// Regenerate config and reload xray.
    pub async fn regenerate_and_reload(&self, pool: &PgPool) {
        self.sync_config(pool).await;
        self.xray_api.reload().await;
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        if self.xray_api.health_check().await {
            info!("Xray reloaded and healthy");
        } else {
            warn!("Xray config written but health check failed");
        }
    }
}

// ── Types ──

#[derive(Debug, Clone)]
pub struct ActiveUser {
    pub username: String,
    pub uuid: String,
    pub short_id: String,
}

// ── Helpers ──

fn to_credentials(users: &[ActiveUser]) -> (Vec<UserCredentials>, Vec<String>) {
    let mut short_ids = vec![String::new()];
    let creds: Vec<UserCredentials> = users.iter().map(|u| {
        if !u.short_id.is_empty() { short_ids.push(u.short_id.clone()); }
        UserCredentials { username: u.username.clone(), uuid: u.uuid.clone(), short_id: u.short_id.clone() }
    }).collect();
    short_ids.sort();
    short_ids.dedup();
    (creds, short_ids)
}

fn ensure_default_outbounds(outbounds: &mut Vec<serde_json::Value>) {
    let tags: Vec<String> = outbounds.iter().filter_map(|o| o.get("tag").and_then(|t| t.as_str()).map(String::from)).collect();
    if !tags.contains(&"DIRECT".to_string()) {
        outbounds.insert(0, json!({"protocol": "freedom", "tag": "DIRECT", "settings": {"domainStrategy": "UseIPv4"}}));
    }
    if !tags.contains(&"BLOCK".to_string()) {
        outbounds.push(json!({"protocol": "blackhole", "tag": "BLOCK"}));
    }
}

fn stats_api_inbound(port: u16) -> serde_json::Value {
    json!({"tag": "api", "listen": "0.0.0.0", "port": port, "protocol": "dokodemo-door", "settings": {"address": "0.0.0.0"}})
}

fn xray_inbound_to_json(ib: &XrayInbound) -> serde_json::Value {
    let mut d = json!({"tag": ib.tag, "port": ib.port, "protocol": ib.protocol});
    if ib.listen != "0.0.0.0" { d["listen"] = json!(ib.listen); }
    if !ib.settings.is_null() { d["settings"] = ib.settings.clone(); }
    if !ib.stream_settings.is_null() { d["streamSettings"] = ib.stream_settings.clone(); }
    if !ib.sniffing.is_null() { d["sniffing"] = ib.sniffing.clone(); }
    d
}

async fn load_active_users(pool: &PgPool) -> Vec<ActiveUser> {
    let rows: Vec<(Option<String>, Option<String>, Option<String>)> = match sqlx::query_as(
        "SELECT vpn_username, vpn_uuid, vpn_short_id FROM users WHERE is_active = true AND vpn_uuid IS NOT NULL"
    )
    .fetch_all(pool)
    .await {
        Ok(r) => r,
        Err(e) => {
            tracing::error!(error = %e, "CRITICAL: Failed to load active users from DB — config will NOT be regenerated");
            return vec![];
        }
    };

    rows.into_iter().filter_map(|(username, uuid, short_id)| {
        Some(ActiveUser {
            username: username?,
            uuid: uuid?,
            short_id: short_id.unwrap_or_default(),
        })
    }).collect()
}
