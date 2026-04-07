//! Shared types for the protocol plugin system.
//! Matches Python base.py 1:1.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Server configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    pub domain: String,
    pub flag: String,
    pub name: String,
    pub key: String, // e.g. "msk", "nl", "de"
    #[serde(default)]
    pub sni: String, // per-server Reality SNI override (empty = use global)
}

/// VPN user credentials.
#[derive(Debug, Clone)]
pub struct UserCredentials {
    pub username: String,
    pub uuid: String,
    pub short_id: String,
}

/// Client subscription link.
#[derive(Debug, Clone, Serialize)]
pub struct ClientLink {
    pub uri: String,
    pub protocol: String,
    pub transport: String,
    pub server_key: String,
    pub remark: String,
    #[serde(default)]
    pub is_relay: bool,
}

/// Xray inbound configuration.
#[derive(Debug, Clone, Serialize)]
pub struct XrayInbound {
    pub tag: String,
    pub port: u16,
    pub protocol: String,
    #[serde(default)]
    pub settings: serde_json::Value,
    #[serde(default, rename = "streamSettings")]
    pub stream_settings: serde_json::Value,
    #[serde(default)]
    pub sniffing: serde_json::Value,
    #[serde(default = "default_listen")]
    pub listen: String,
}

fn default_listen() -> String {
    "0.0.0.0".to_string()
}

/// Options passed to singbox_outbound.
#[derive(Debug, Clone, Default)]
pub struct OutboundOpts {
    pub transport: Option<String>,
    pub sni: Option<String>,
    pub network: Option<String>,
}

impl ServerConfig {
    /// Resolve effective host: prefer domain over raw IP.
    pub fn effective_host(&self) -> &str {
        if self.domain.is_empty() { &self.host } else { &self.domain }
    }

    /// Resolve host with optional override domain.
    pub fn resolve_host<'a>(&'a self, override_domain: &'a str) -> &'a str {
        if override_domain.is_empty() { self.effective_host() } else { override_domain }
    }

    /// Format server remark: "🇩🇪 Germany {suffix}"
    pub fn remark(&self, suffix: &str) -> String {
        format!("{} {} {}", self.flag, self.name, suffix)
    }
}

/// Protocol plugin trait — every VPN protocol must implement this.
pub trait Protocol: Send + Sync {
    fn name(&self) -> &str;
    fn display_name(&self) -> &str;
    fn enabled(&self) -> bool { true }
    /// Primary port for this protocol (0 if no dedicated port).
    fn port(&self) -> u16 { 0 }

    /// Generate xray inbound configs for this protocol.
    fn xray_inbounds(&self, users: &[UserCredentials], short_ids: &[String]) -> Vec<XrayInbound>;

    /// Optional xray outbounds (e.g. WARP WireGuard, FinalMask).
    fn xray_outbounds(&self) -> Vec<serde_json::Value> { vec![] }

    /// Optional xray routing rules.
    fn xray_routing_rules(&self) -> Vec<serde_json::Value> { vec![] }

    /// Generate client subscription links.
    fn client_links(&self, user: &UserCredentials, servers: &[ServerConfig]) -> Vec<ClientLink>;

    /// Generate sing-box outbound config for native iOS/macOS app.
    fn singbox_outbound(
        &self, tag: &str, server: &ServerConfig, user: &UserCredentials, opts: &OutboundOpts,
    ) -> Option<serde_json::Value>;

    /// Inbounds for remote nodes (defaults to xray_inbounds).
    fn node_inbounds(&self, users: &[UserCredentials], short_ids: &[String]) -> Vec<XrayInbound> {
        self.xray_inbounds(users, short_ids)
    }
}
