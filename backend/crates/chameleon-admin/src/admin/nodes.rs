//! Node management endpoints.
//! GET  /nodes                    — list nodes with system metrics, traffic, protocols
//! POST /nodes/sync               — trigger config sync (regenerate + reload)
//! POST /nodes/restart-xray       — regenerate xray config and reload
//! GET  /nodes/{key}/history      — metrics time series for charts

use std::time::{Duration, Instant};
use axum::{
    extract::{Path, Query, State},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use tokio::net::TcpStream;
use chameleon_auth::AuthAdmin;
use chameleon_config::get_settings;
use chameleon_core::{ChameleonCore, error::ApiResult};
use chameleon_vpn::protocols::ProtocolRegistry;

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/nodes", get(list_nodes))
        .route("/nodes/sync", post(sync_nodes))
        .route("/nodes/restart-xray", post(restart_xray))
        .route("/nodes/{key}/history", get(node_history))
}

// ── Response types ──

#[derive(Serialize)]
struct NodesResponse {
    nodes: Vec<NodeInfo>,
    total_cost_monthly_rub: i64,
}

#[derive(Serialize)]
struct NodeInfo {
    key: String,
    name: String,
    flag: String,
    ip: String,
    is_active: bool,
    latency_ms: Option<f64>,
    cpu: Option<f64>,
    ram_used: Option<f64>,
    ram_total: Option<f64>,
    disk: Option<f64>,
    user_count: i32,
    uptime_hours: Option<f64>,
    xray_version: Option<String>,
    // New fields
    traffic_up: i64,
    traffic_down: i64,
    online_users: i32,
    protocols: Vec<ProtocolStatus>,
}

#[derive(Serialize, Clone)]
struct ProtocolStatus {
    name: String,
    display_name: String,
    enabled: bool,
    port: u16,
}

// ── Helpers ──

async fn tcp_ping(host: &str, port: u16) -> Option<f64> {
    let addr = format!("{host}:{port}");
    let start = Instant::now();
    match tokio::time::timeout(Duration::from_secs(3), TcpStream::connect(&addr)).await {
        Ok(Ok(_)) => Some(start.elapsed().as_secs_f64() * 1000.0),
        _ => None,
    }
}

async fn active_user_count(pool: &PgPool) -> i32 {
    sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM users WHERE is_active = true")
        .fetch_one(pool)
        .await
        .unwrap_or(0) as i32
}

/// Read system metrics from /proc (Linux only).
fn read_system_metrics() -> (Option<f64>, Option<f64>, Option<f64>, Option<f64>, Option<f64>) {
    let cpu = read_cpu_usage();
    let (ram_used, ram_total) = read_memory();
    let disk = read_disk_usage();
    let uptime = read_uptime();
    (cpu, ram_used, ram_total, disk, uptime)
}

fn read_cpu_usage() -> Option<f64> {
    let loadavg = std::fs::read_to_string("/host/proc/loadavg")
        .or_else(|_| std::fs::read_to_string("/proc/loadavg")).ok()?;
    let load: f64 = loadavg.split_whitespace().next()?.parse().ok()?;
    let cpus = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1) as f64;
    Some(((load / cpus) * 100.0).min(100.0).round())
}

fn read_memory() -> (Option<f64>, Option<f64>) {
    let meminfo = std::fs::read_to_string("/host/proc/meminfo")
        .or_else(|_| std::fs::read_to_string("/proc/meminfo")).ok();
    let meminfo = match meminfo {
        Some(m) => m,
        None => return (None, None),
    };

    let mut total_kb: f64 = 0.0;
    let mut available_kb: f64 = 0.0;

    for line in meminfo.lines() {
        if line.starts_with("MemTotal:") {
            total_kb = line.split_whitespace().nth(1)
                .and_then(|v| v.parse().ok()).unwrap_or(0.0);
        } else if line.starts_with("MemAvailable:") {
            available_kb = line.split_whitespace().nth(1)
                .and_then(|v| v.parse().ok()).unwrap_or(0.0);
        }
    }

    if total_kb > 0.0 {
        let total_mb = (total_kb / 1024.0).round();
        let used_mb = ((total_kb - available_kb) / 1024.0).round();
        (Some(used_mb), Some(total_mb))
    } else {
        (None, None)
    }
}

fn read_disk_usage() -> Option<f64> {
    let output = std::process::Command::new("df")
        .args(["--output=pcent", "/"])
        .output().ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let pct = stdout.lines().nth(1)?
        .trim().trim_end_matches('%')
        .parse::<f64>().ok()?;
    Some(pct)
}

fn read_uptime() -> Option<f64> {
    let uptime = std::fs::read_to_string("/host/proc/uptime")
        .or_else(|_| std::fs::read_to_string("/proc/uptime")).ok()?;
    let secs: f64 = uptime.split_whitespace().next()?.parse().ok()?;
    Some((secs / 3600.0 * 10.0).round() / 10.0)
}

/// Build protocol status list from registry.
fn build_protocol_statuses() -> Vec<ProtocolStatus> {
    let settings = get_settings();
    let registry = ProtocolRegistry::new(settings);
    registry.all().iter().map(|p| {
        ProtocolStatus {
            name: p.name().to_string(),
            display_name: p.display_name().to_string(),
            enabled: p.enabled(),
            port: p.port(),
        }
    }).collect()
}

// ── Handlers ──

async fn list_nodes(
    State(state): State<ChameleonCore>,
    _admin: AuthAdmin,
) -> ApiResult<Json<NodesResponse>> {
    let servers = state.engine.build_server_configs();
    let protocols = build_protocol_statuses();

    // Spawn parallel tasks
    let db = state.db.clone();
    let engine = state.engine.clone();
    let engine2 = state.engine.clone();
    let user_count_handle = tokio::spawn(async move { active_user_count(&db).await });
    let xray_health_handle = tokio::spawn(async move { engine.xray_api().health_check().await });
    let metrics_handle = tokio::spawn(async { read_system_metrics() });
    let traffic_handle = tokio::spawn(async move { engine2.xray_api().query_total_traffic().await });
    let engine3 = state.engine.clone();
    let online_handle = tokio::spawn(async move { engine3.xray_api().count_online_users().await });

    let vless_port = state.config.vless_tcp_port;
    let mut ping_handles = vec![];
    for srv in &servers {
        let host = srv.host.clone();
        ping_handles.push(tokio::spawn(async move {
            tcp_ping(&host, vless_port).await
        }));
    }

    let user_count = user_count_handle.await.unwrap_or(0);
    let xray_healthy = xray_health_handle.await.unwrap_or(false);
    let (cpu, ram_used, ram_total, disk, uptime) = metrics_handle.await
        .unwrap_or((None, None, None, None, None));
    let (traffic_up, traffic_down) = traffic_handle.await.unwrap_or((0, 0));
    let online_users = online_handle.await.unwrap_or(0);

    let mut nodes = vec![];
    for (i, handle) in ping_handles.into_iter().enumerate() {
        let latency = handle.await.ok().flatten();
        let srv = &servers[i];
        let is_active = latency.is_some() || xray_healthy;
        nodes.push(NodeInfo {
            key: srv.key.clone(),
            name: srv.name.clone(),
            flag: srv.flag.clone(),
            ip: srv.host.clone(),
            is_active,
            latency_ms: latency.map(|l| (l * 10.0).round() / 10.0),
            cpu,
            ram_used,
            ram_total,
            disk,
            user_count,
            uptime_hours: uptime,
            xray_version: Some(state.config.xray_version.clone()),
            traffic_up,
            traffic_down,
            online_users,
            protocols: protocols.clone(),
        });
    }

    Ok(Json(NodesResponse { nodes, total_cost_monthly_rub: 0 }))
}

async fn sync_nodes(
    State(state): State<ChameleonCore>,
    _admin: AuthAdmin,
) -> ApiResult<Json<serde_json::Value>> {
    state.engine.regenerate_and_reload(&state.db).await;
    Ok(Json(serde_json::json!({"ok": true})))
}

async fn restart_xray(
    State(state): State<ChameleonCore>,
    _admin: AuthAdmin,
) -> ApiResult<Json<serde_json::Value>> {
    state.engine.regenerate_and_reload(&state.db).await;
    let healthy = state.engine.xray_api().health_check().await;
    Ok(Json(serde_json::json!({
        "ok": true,
        "xray_healthy": healthy,
    })))
}

// ── History endpoint ──

#[derive(Deserialize)]
struct HistoryQuery {
    hours: Option<i64>,
}

#[derive(Serialize, sqlx::FromRow)]
struct MetricsPoint {
    cpu: Option<f32>,
    ram_used: Option<f32>,
    ram_total: Option<f32>,
    disk: Option<f32>,
    traffic_up: Option<i64>,
    traffic_down: Option<i64>,
    online_users: Option<i32>,
    recorded_at: chrono::DateTime<chrono::Utc>,
}

async fn node_history(
    State(state): State<ChameleonCore>,
    _admin: AuthAdmin,
    Path(key): Path<String>,
    Query(params): Query<HistoryQuery>,
) -> ApiResult<Json<serde_json::Value>> {
    let hours = params.hours.unwrap_or(24).min(168); // max 7 days
    let since = chrono::Utc::now() - chrono::Duration::hours(hours);

    let points: Vec<MetricsPoint> = sqlx::query_as(
        "SELECT cpu, ram_used, ram_total, disk, traffic_up, traffic_down, online_users, recorded_at
         FROM node_metrics_history
         WHERE node_key = $1 AND recorded_at >= $2
         ORDER BY recorded_at ASC"
    )
    .bind(&key)
    .bind(since)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Ok(Json(serde_json::json!({
        "node_key": key,
        "hours": hours,
        "points": points,
    })))
}

