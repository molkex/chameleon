//! Xray gRPC API client — direct gRPC connection (no Docker CLI dependency).
//!
//! Uses the `xray-core` crate for pre-compiled protobuf bindings.
//! Connects to xray's gRPC API (default: xray:10085 on Docker network).

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use tonic::transport::Channel;
use tracing::{debug, error, info, warn};

use xray_core::app::proxyman::command::{
    handler_service_client::HandlerServiceClient,
    AlterInboundRequest,
};
use xray_core::app::stats::command::{
    stats_service_client::StatsServiceClient,
    QueryStatsRequest, SysStatsRequest,
};

/// Inbound tag definitions — email suffix and flow for each inbound.
pub struct InboundDef {
    pub tag: &'static str,
    pub suffix: &'static str,
    pub flow: &'static str,
}

pub static INBOUND_DEFS: &[InboundDef] = &[
    InboundDef { tag: "VLESS TCP REALITY", suffix: "xray", flow: "xtls-rprx-vision" },
    InboundDef { tag: "VLESS XHTTP REALITY", suffix: "xhttp", flow: "" },
    InboundDef { tag: "VLESS XHTTP H2 REALITY", suffix: "xhttp2", flow: "" },
    InboundDef { tag: "VLESS WS CDN", suffix: "ws", flow: "" },
];

/// gRPC-based xray API client.
pub struct XrayApi {
    addr: String,
    stats: Arc<Mutex<Option<StatsServiceClient<Channel>>>>,
    handler: Arc<Mutex<Option<HandlerServiceClient<Channel>>>>,
}

impl XrayApi {
    pub fn new(addr: &str) -> Self {
        // Validate address format
        assert!(
            addr.contains(':') && addr.len() <= 256,
            "Invalid xray gRPC address: {addr}"
        );
        Self {
            addr: addr.to_string(),
            stats: Arc::new(Mutex::new(None)),
            handler: Arc::new(Mutex::new(None)),
        }
    }

    /// Create a lazy channel to xray gRPC. Connection is established on first request.
    fn get_channel(&self) -> Result<Channel, tonic::transport::Error> {
        let endpoint = format!("http://{}", self.addr);
        Ok(Channel::from_shared(endpoint)
            .expect("valid URI")
            .connect_timeout(std::time::Duration::from_secs(5))
            .timeout(std::time::Duration::from_secs(10))
            .connect_lazy())
    }

    async fn stats_client(&self) -> Option<StatsServiceClient<Channel>> {
        let mut guard = self.stats.lock().await;
        if guard.is_none() {
            match self.get_channel() {
                Ok(ch) => *guard = Some(StatsServiceClient::new(ch)),
                Err(e) => { warn!(error = %e, "Failed to create xray stats channel"); return None; }
            }
        }
        guard.clone()
    }

    async fn handler_client(&self) -> Option<HandlerServiceClient<Channel>> {
        let mut guard = self.handler.lock().await;
        if guard.is_none() {
            match self.get_channel() {
                Ok(ch) => *guard = Some(HandlerServiceClient::new(ch)),
                Err(e) => { warn!(error = %e, "Failed to create xray handler channel"); return None; }
            }
        }
        guard.clone()
    }

    /// Reset cached connections (e.g. after xray restart).
    pub async fn reset_connections(&self) {
        *self.stats.lock().await = None;
        *self.handler.lock().await = None;
    }

    // ── User Management ──

    pub async fn add_user(&self, inbound_tag: &str, uuid: &str, email: &str, flow: &str) -> bool {
        let Some(mut client) = self.handler_client().await else { return false; };

        use prost::Message;

        // Build VLESS Account as protobuf
        let account = xray_core::proxy::vless::Account {
            id: uuid.to_string(),
            flow: flow.to_string(),
            encryption: "none".to_string(),
        };

        // Encode account to protobuf bytes
        let mut account_bytes = Vec::new();
        account.encode(&mut account_bytes).unwrap_or_default();

        // Wrap in AddUserOperation
        let op = xray_core::app::proxyman::command::AddUserOperation {
            user: Some(xray_core::common::protocol::User {
                level: 0,
                email: email.to_string(),
                account: Some(xray_core::common::serial::TypedMessage {
                    r#type: "xray.proxy.vless.Account".to_string(),
                    value: account_bytes,
                }),
            }),
        };

        // Encode operation to protobuf bytes
        let mut op_bytes = Vec::new();
        op.encode(&mut op_bytes).unwrap_or_default();

        let request = AlterInboundRequest {
            tag: inbound_tag.to_string(),
            operation: Some(xray_core::common::serial::TypedMessage {
                r#type: "xray.app.proxyman.command.AddUserOperation".to_string(),
                value: op_bytes,
            }),
        };

        match client.alter_inbound(request).await {
            Ok(_) => true,
            Err(e) => {
                warn!(tag = inbound_tag, email, error = %e, "add_user gRPC failed");
                if e.code() == tonic::Code::Unavailable {
                    self.reset_connections().await;
                }
                false
            }
        }
    }

    pub async fn remove_user(&self, inbound_tag: &str, email: &str) -> bool {
        let Some(mut client) = self.handler_client().await else { return false; };

        use prost::Message;

        let op = xray_core::app::proxyman::command::RemoveUserOperation {
            email: email.to_string(),
        };

        let mut op_bytes = Vec::new();
        op.encode(&mut op_bytes).unwrap_or_default();

        let request = AlterInboundRequest {
            tag: inbound_tag.to_string(),
            operation: Some(xray_core::common::serial::TypedMessage {
                r#type: "xray.app.proxyman.command.RemoveUserOperation".to_string(),
                value: op_bytes,
            }),
        };

        match client.alter_inbound(request).await {
            Ok(_) => true,
            Err(e) => {
                debug!(tag = inbound_tag, email, error = %e, "remove_user gRPC failed");
                false
            }
        }
    }

    pub async fn add_user_to_all_inbounds(&self, uuid: &str, username: &str, _short_id: &str) -> bool {
        let mut ok = 0usize;
        for d in INBOUND_DEFS {
            let email = format!("{username}@{}", d.suffix);
            if self.add_user(d.tag, uuid, &email, d.flow).await { ok += 1; }
        }
        if ok < INBOUND_DEFS.len() {
            warn!(username, ok, total = INBOUND_DEFS.len(), "add_user_to_all: partial success");
        }
        ok > 0
    }

    pub async fn remove_user_from_all_inbounds(&self, username: &str) -> bool {
        let mut any_ok = false;
        for d in INBOUND_DEFS {
            let email = format!("{username}@{}", d.suffix);
            if self.remove_user(d.tag, &email).await { any_ok = true; }
        }
        any_ok
    }

    // ── Stats ──

    pub async fn query_all_traffic(&self) -> HashMap<String, TrafficStats> {
        let Some(mut client) = self.stats_client().await else {
            return HashMap::new();
        };

        let request = QueryStatsRequest {
            pattern: "user>>>".to_string(),
            reset: false,
        };

        let response = match client.query_stats(request).await {
            Ok(r) => r.into_inner(),
            Err(e) => {
                warn!(error = %e, "query_all_traffic gRPC failed");
                return HashMap::new();
            }
        };

        let mut result: HashMap<String, TrafficStats> = HashMap::new();
        for stat in response.stat {
            // Format: "user>>>email>>>traffic>>>uplink/downlink"
            let parts: Vec<&str> = stat.name.split(">>>").collect();
            if parts.len() == 4 {
                let uname = parts[1].split('@').next().unwrap_or("");
                let entry = result.entry(uname.to_string()).or_default();
                if parts[3] == "uplink" { entry.up += stat.value; }
                else { entry.down += stat.value; }
            }
        }
        result
    }

    /// Query total server traffic (all users combined).
    /// Returns (total_up, total_down) in bytes.
    pub async fn query_total_traffic(&self) -> (i64, i64) {
        let Some(mut client) = self.stats_client().await else {
            return (0, 0);
        };

        let request = QueryStatsRequest {
            pattern: "user>>>".to_string(),
            reset: false,
        };

        let response = match client.query_stats(request).await {
            Ok(r) => r.into_inner(),
            Err(e) => {
                warn!(error = %e, "query_total_traffic gRPC failed");
                return (0, 0);
            }
        };

        let mut up: i64 = 0;
        let mut down: i64 = 0;
        for stat in response.stat {
            let parts: Vec<&str> = stat.name.split(">>>").collect();
            if parts.len() == 4 {
                if parts[3] == "uplink" { up += stat.value; }
                else { down += stat.value; }
            }
        }
        (up, down)
    }

    /// Count online users — users with any traffic in xray stats.
    /// This counts distinct usernames that have non-zero traffic counters.
    pub async fn count_online_users(&self) -> i32 {
        let traffic = self.query_all_traffic().await;
        traffic.values().filter(|s| s.up > 0 || s.down > 0).count() as i32
    }

    // ── Health ──

    pub async fn health_check(&self) -> bool {
        let Some(mut client) = self.stats_client().await else { return false; };
        match client.get_sys_stats(SysStatsRequest {}).await {
            Ok(_) => true,
            Err(e) => {
                warn!(error = %e, "Xray health check gRPC failed");
                // Reset so next call creates fresh channel
                self.reset_connections().await;
                false
            }
        }
    }

    /// Reset connections so next gRPC call reconnects fresh.
    /// Config file is already written by the caller — this ensures gRPC clients reconnect.
    pub async fn reload(&self) -> bool {
        self.reset_connections().await;
        // Give xray a moment, then verify
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        self.health_check().await
    }
}

#[derive(Debug, Default, Clone)]
pub struct TrafficStats {
    pub up: i64,
    pub down: i64,
}
