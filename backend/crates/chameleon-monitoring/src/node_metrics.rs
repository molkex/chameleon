//! Node metrics collection — TCP ping + SSH-based system metrics.
//! Simplified version — SSH metrics deferred to later iteration.

use std::time::{Duration, Instant};
use tokio::net::TcpStream;
use tracing::{debug, warn};

/// TCP ping to check if a host:port is reachable. Returns latency in ms.
pub async fn tcp_ping(host: &str, port: u16, timeout: Duration) -> Option<f64> {
    let addr = format!("{host}:{port}");
    let start = Instant::now();
    match tokio::time::timeout(timeout, TcpStream::connect(&addr)).await {
        Ok(Ok(_)) => {
            let ms = start.elapsed().as_secs_f64() * 1000.0;
            debug!(host, port, ms, "TCP ping OK");
            Some(ms)
        }
        Ok(Err(e)) => {
            warn!(host, port, error = %e, "TCP ping failed");
            None
        }
        Err(_) => {
            warn!(host, port, "TCP ping timed out");
            None
        }
    }
}

/// Node health status.
#[derive(Debug, Clone, serde::Serialize)]
pub struct NodeHealth {
    pub key: String,
    pub name: String,
    pub host: String,
    pub is_active: bool,
    pub latency_ms: Option<f64>,
    pub cpu: Option<f64>,
    pub ram_used: Option<f64>,
    pub ram_total: Option<f64>,
    pub disk: Option<f64>,
    pub user_count: i32,
}

/// Check node health via TCP ping (SSH metrics can be added later).
pub async fn check_node_health(
    key: &str,
    name: &str,
    host: &str,
    port: u16,
) -> NodeHealth {
    let latency = tcp_ping(host, port, Duration::from_secs(5)).await;
    NodeHealth {
        key: key.to_string(),
        name: name.to_string(),
        host: host.to_string(),
        is_active: latency.is_some(),
        latency_ms: latency,
        cpu: None,
        ram_used: None,
        ram_total: None,
        disk: None,
        user_count: 0,
    }
}
