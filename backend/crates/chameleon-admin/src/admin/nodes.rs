//! Node management endpoints.
//! GET /nodes — list nodes with TCP ping health check
//! POST /nodes/sync — trigger config sync

use std::time::{Duration, Instant};
use axum::{extract::State, routing::{get, post}, Json, Router};
use serde::Serialize;
use sqlx::PgPool;
use tokio::net::TcpStream;

use chameleon_auth::AuthAdmin;
use chameleon_core::{ChameleonCore, error::ApiResult};

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/nodes", get(list_nodes))
        .route("/nodes/sync", post(sync_nodes))
}

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
}

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

async fn list_nodes(
    State(state): State<ChameleonCore>,
    _admin: AuthAdmin,
) -> ApiResult<Json<NodesResponse>> {
    let servers = state.engine.build_server_configs();

    // Fetch active user count and xray health in parallel with pings
    let db = state.db.clone();
    let engine = state.engine.clone();
    let user_count_handle = tokio::spawn(async move { active_user_count(&db).await });
    let xray_health_handle = tokio::spawn(async move { engine.xray_api().health_check().await });

    // Ping all servers concurrently
    let vless_port = state.config.vless_tcp_port;
    let mut handles = vec![];
    for srv in &servers {
        let host = srv.host.clone();
        handles.push(tokio::spawn(async move {
            tcp_ping(&host, vless_port).await
        }));
    }

    let user_count = user_count_handle.await.unwrap_or(0);
    let xray_healthy = xray_health_handle.await.unwrap_or(false);

    let mut nodes = vec![];
    for (i, handle) in handles.into_iter().enumerate() {
        let latency = handle.await.ok().flatten();
        let srv = &servers[i];
        // Node is active if TCP ping succeeded or (for this node) xray is healthy
        let is_active = latency.is_some() || xray_healthy;
        nodes.push(NodeInfo {
            key: srv.key.clone(),
            name: srv.name.clone(),
            flag: srv.flag.clone(),
            ip: srv.host.clone(),
            is_active,
            latency_ms: latency.map(|l| (l * 10.0).round() / 10.0),
            cpu: None,
            ram_used: None,
            ram_total: None,
            disk: None,
            user_count,
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
