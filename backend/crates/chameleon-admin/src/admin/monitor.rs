//! Monitor endpoints.
//! GET /monitor — resource checks + uptime

use axum::{extract::State, routing::get, Json, Router};
use chrono::{Utc, Duration, NaiveDateTime};
use serde::Serialize;

use chameleon_auth::AuthAdmin;
use chameleon_core::{ChameleonCore, error::{ApiError, ApiResult}};

pub fn router() -> Router<ChameleonCore> {
    Router::new().route("/monitor", get(monitor))
}

#[derive(Serialize)]
struct MonitorResponse {
    checks: Vec<CheckItem>,
    uptime_vpn: Option<f64>,
    uptime_residential: Option<f64>,
    uptime_direct: Option<f64>,
}

#[derive(Serialize)]
struct CheckItem {
    resource: String,
    url: String,
    is_available: bool,
    response_time_ms: Option<f64>,
    protocol: String,
    checked_at: String,
}

async fn monitor(
    State(state): State<ChameleonCore>,
    _admin: AuthAdmin,
) -> ApiResult<Json<MonitorResponse>> {
    let _24h_ago = Utc::now().naive_utc() - Duration::hours(24);

    // Latest checks per resource
    let checks: Vec<(Option<String>, Option<String>, Option<bool>, Option<f64>, Option<String>, Option<NaiveDateTime>)> = sqlx::query_as(
        "SELECT mc.resource, mc.url, mc.is_available, mc.response_time_ms, mc.protocol, mc.checked_at
         FROM monitor_checks mc
         INNER JOIN (SELECT resource, MAX(checked_at) as max_ts FROM monitor_checks GROUP BY resource) latest
         ON mc.resource = latest.resource AND mc.checked_at = latest.max_ts
         ORDER BY mc.resource"
    ).fetch_all(&state.db).await.unwrap_or_default();

    let check_items: Vec<CheckItem> = checks.into_iter().map(|(res, url, avail, rt, proto, ts)| {
        CheckItem {
            resource: res.unwrap_or_default(),
            url: url.unwrap_or_default(),
            is_available: avail.unwrap_or(false),
            response_time_ms: rt,
            protocol: proto.unwrap_or_default(),
            checked_at: ts.map(|t| t.format("%d.%m %H:%M").to_string()).unwrap_or_default(),
        }
    }).collect();

    // Uptime per category
    let uptime_vpn = calc_uptime(&state.db, _24h_ago, "vpn").await;
    let uptime_res = calc_uptime(&state.db, _24h_ago, "residential").await;
    let uptime_direct = calc_uptime(&state.db, _24h_ago, "direct").await;

    Ok(Json(MonitorResponse { checks: check_items, uptime_vpn, uptime_residential: uptime_res, uptime_direct }))
}

async fn calc_uptime(pool: &sqlx::PgPool, since: NaiveDateTime, category: &str) -> Option<f64> {
    let (total,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM monitor_checks WHERE checked_at >= $1 AND category = $2"
    ).bind(since).bind(category).fetch_one(pool).await.ok()?;
    if total == 0 { return None; }

    let (available,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM monitor_checks WHERE checked_at >= $1 AND category = $2 AND is_available = true"
    ).bind(since).bind(category).fetch_one(pool).await.ok()?;

    Some((available as f64 / total as f64 * 1000.0).round() / 10.0)
}
