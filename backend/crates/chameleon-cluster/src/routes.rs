//! Cluster API endpoints for mesh synchronization.

use axum::{
    Router,
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Json,
};
use chrono::NaiveDateTime;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use tracing::{info, warn};

use chameleon_core::ChameleonCore;

// ── Request / Response types ──

#[derive(Debug, Deserialize)]
pub struct SyncQuery {
    pub since: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct SyncUser {
    pub id: i32,
    pub vpn_username: Option<String>,
    pub vpn_uuid: Option<String>,
    pub vpn_short_id: Option<String>,
    pub apple_id: Option<String>,
    pub device_id: Option<String>,
    pub auth_provider: Option<String>,
    pub is_active: bool,
    pub subscription_expiry: Option<NaiveDateTime>,
    pub subscription_token: Option<String>,
    pub activation_code: Option<String>,
    pub original_transaction_id: Option<String>,
    pub current_plan: Option<String>,
    pub created_at: Option<NaiveDateTime>,
    pub updated_at: Option<NaiveDateTime>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SyncResponse {
    pub users: Vec<SyncUser>,
    pub node_id: String,
    pub timestamp: i64,
}

#[derive(Debug, Deserialize)]
pub struct PushRequest {
    pub users: Vec<SyncUser>,
    pub node_id: String,
}

#[derive(Debug, Serialize)]
pub struct PushResponse {
    pub accepted: usize,
    pub node_id: String,
}

#[derive(Debug, Serialize)]
pub struct HealthResponse {
    pub node_id: String,
    pub status: String,
    pub users: i64,
    pub uptime: i64,
    pub peers: Vec<String>,
    pub last_sync: Option<NaiveDateTime>,
}

#[derive(Debug, Deserialize)]
pub struct JoinRequest {
    pub node_id: String,
    pub url: String,
    pub ip: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct JoinResponse {
    pub ok: bool,
    pub node_id: String,
    pub peers: Vec<String>,
}

// ── Router ──

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/sync", get(get_sync).post(post_sync))
        .route("/health", get(health))
        .route("/join", post(join))
}

// ── Auth helper ──

fn verify_cluster_secret(headers: &HeaderMap, expected: &str) -> Result<(), StatusCode> {
    if expected.is_empty() {
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }
    let provided = headers
        .get("X-Cluster-Secret")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if provided != expected {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(())
}

// ── GET /sync?since=<timestamp> ──

async fn get_sync(
    State(core): State<ChameleonCore>,
    headers: HeaderMap,
    Query(q): Query<SyncQuery>,
) -> Result<impl IntoResponse, StatusCode> {
    verify_cluster_secret(&headers, &core.config.cluster_secret)?;

    let since_ts = q.since.unwrap_or(0);
    let since_dt = chrono::DateTime::from_timestamp(since_ts, 0)
        .map(|dt| dt.naive_utc())
        .unwrap_or_else(|| chrono::DateTime::UNIX_EPOCH.naive_utc());

    let users = get_changes_since_dt(&core.db, since_dt)
        .await
        .map_err(|e| {
            warn!(error = %e, "Failed to fetch changes");
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let now = chrono::Utc::now().timestamp();

    Ok(Json(SyncResponse {
        users,
        node_id: core.config.node_id.clone(),
        timestamp: now,
    }))
}

// ── POST /sync ──

async fn post_sync(
    State(core): State<ChameleonCore>,
    headers: HeaderMap,
    Json(payload): Json<PushRequest>,
) -> Result<impl IntoResponse, StatusCode> {
    verify_cluster_secret(&headers, &core.config.cluster_secret)?;

    let count = payload.users.len();
    info!(
        peer = %payload.node_id,
        users = count,
        "Receiving sync push"
    );

    upsert_users(&core.db, &payload.users).await.map_err(|e| {
        warn!(error = %e, "Failed to upsert users");
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    Ok(Json(PushResponse {
        accepted: count,
        node_id: core.config.node_id.clone(),
    }))
}

// ── GET /health ──

async fn health(State(core): State<ChameleonCore>) -> impl IntoResponse {
    let user_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
        .fetch_one(&core.db)
        .await
        .unwrap_or(0);

    let peers = get_peer_ids(&core.db).await.unwrap_or_default();

    let last_sync: Option<NaiveDateTime> =
        sqlx::query_scalar("SELECT MAX(last_sync) FROM cluster_peers WHERE is_active = true")
            .fetch_one(&core.db)
            .await
            .unwrap_or(None);

    // Approximate uptime via pg_postmaster_start_time (good enough for health check)
    let uptime: i64 = sqlx::query_scalar(
        "SELECT EXTRACT(EPOCH FROM (NOW() - pg_postmaster_start_time()))::bigint",
    )
    .fetch_one(&core.db)
    .await
    .unwrap_or(0);

    Json(HealthResponse {
        node_id: core.config.node_id.clone(),
        status: "ok".into(),
        users: user_count,
        uptime,
        peers,
        last_sync,
    })
}

// ── POST /join ──

async fn join(
    State(core): State<ChameleonCore>,
    headers: HeaderMap,
    Json(payload): Json<JoinRequest>,
) -> Result<impl IntoResponse, StatusCode> {
    verify_cluster_secret(&headers, &core.config.cluster_secret)?;

    info!(
        peer_node = %payload.node_id,
        peer_url = %payload.url,
        "Peer join request"
    );

    sqlx::query(
        r#"
        INSERT INTO cluster_peers (node_id, url, ip, is_active, last_sync)
        VALUES ($1, $2, $3, true, NOW())
        ON CONFLICT (node_id) DO UPDATE SET
            url = EXCLUDED.url,
            ip = EXCLUDED.ip,
            is_active = true,
            last_sync = NOW()
        "#,
    )
    .bind(&payload.node_id)
    .bind(&payload.url)
    .bind(&payload.ip)
    .execute(&core.db)
    .await
    .map_err(|e| {
        warn!(error = %e, "Failed to register peer");
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    let peers = get_peer_ids(&core.db).await.unwrap_or_default();

    Ok(Json(JoinResponse {
        ok: true,
        node_id: core.config.node_id.clone(),
        peers,
    }))
}

// ── DB helpers ──

pub async fn get_changes_since_dt(
    db: &PgPool,
    since: NaiveDateTime,
) -> anyhow::Result<Vec<SyncUser>> {
    let rows: Vec<SyncUser> = sqlx::query_as(
        r#"
        SELECT
            id, vpn_username, vpn_uuid, vpn_short_id,
            apple_id, device_id, auth_provider,
            is_active, subscription_expiry,
            subscription_token, activation_code,
            original_transaction_id, current_plan,
            created_at, updated_at
        FROM users
        WHERE updated_at > $1
        ORDER BY updated_at ASC
        LIMIT 1000
        "#,
    )
    .bind(since)
    .fetch_all(db)
    .await?;
    Ok(rows)
}

pub async fn upsert_users(db: &PgPool, users: &[SyncUser]) -> anyhow::Result<()> {
    for user in users {
        // Skip users without vpn_username — can't upsert without the conflict key
        let Some(ref vpn_username) = user.vpn_username else {
            continue;
        };

        sqlx::query(
            r#"
            INSERT INTO users (
                vpn_username, vpn_uuid, vpn_short_id,
                apple_id, device_id, auth_provider,
                is_active, subscription_expiry,
                subscription_token, activation_code,
                original_transaction_id, current_plan,
                created_at, updated_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
            ON CONFLICT (vpn_username) DO UPDATE SET
                vpn_uuid = EXCLUDED.vpn_uuid,
                vpn_short_id = EXCLUDED.vpn_short_id,
                apple_id = EXCLUDED.apple_id,
                device_id = EXCLUDED.device_id,
                auth_provider = EXCLUDED.auth_provider,
                is_active = EXCLUDED.is_active,
                subscription_expiry = EXCLUDED.subscription_expiry,
                subscription_token = EXCLUDED.subscription_token,
                activation_code = EXCLUDED.activation_code,
                original_transaction_id = EXCLUDED.original_transaction_id,
                current_plan = EXCLUDED.current_plan,
                updated_at = EXCLUDED.updated_at
            WHERE users.updated_at < EXCLUDED.updated_at
            "#,
        )
        .bind(vpn_username)
        .bind(&user.vpn_uuid)
        .bind(&user.vpn_short_id)
        .bind(&user.apple_id)
        .bind(&user.device_id)
        .bind(&user.auth_provider)
        .bind(user.is_active)
        .bind(user.subscription_expiry)
        .bind(&user.subscription_token)
        .bind(&user.activation_code)
        .bind(&user.original_transaction_id)
        .bind(&user.current_plan)
        .bind(user.created_at)
        .bind(user.updated_at)
        .execute(db)
        .await?;
    }
    Ok(())
}

async fn get_peer_ids(db: &PgPool) -> anyhow::Result<Vec<String>> {
    let rows: Vec<(String,)> =
        sqlx::query_as("SELECT node_id FROM cluster_peers WHERE is_active = true")
            .fetch_all(db)
            .await?;
    Ok(rows.into_iter().map(|r| r.0).collect())
}
