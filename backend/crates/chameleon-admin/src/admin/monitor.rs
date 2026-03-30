//! Monitor endpoints.
//! GET /monitor — resource checks + uptime

use axum::{extract::State, routing::get, Json, Router};
use chrono::{Utc, Duration, NaiveDateTime};
use serde::Serialize;

use chameleon_auth::AuthAdmin;
use chameleon_core::{ChameleonCore, error::ApiResult};

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

    // Latest check per resource (DISTINCT ON avoids self-join)
    let checks: Vec<(Option<String>, Option<String>, Option<bool>, Option<f64>, Option<String>, Option<NaiveDateTime>)> = sqlx::query_as(
        "SELECT DISTINCT ON (resource) resource, url, is_available, response_time_ms, protocol, checked_at
         FROM monitor_checks
         ORDER BY resource, checked_at DESC"
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

    // Uptime per category (single query instead of 6)
    let uptime_rows: Vec<(String, i64, i64)> = sqlx::query_as(
        "SELECT category,
                COUNT(*),
                COUNT(*) FILTER (WHERE is_available = true)
         FROM monitor_checks
         WHERE checked_at >= $1 AND category IN ('vpn', 'residential', 'direct')
         GROUP BY category"
    ).bind(_24h_ago).fetch_all(&state.db).await.unwrap_or_default();

    let calc = |cat: &str| -> Option<f64> {
        uptime_rows.iter().find(|(c, _, _)| c == cat).and_then(|(_, total, avail)| {
            if *total == 0 { None } else { Some((*avail as f64 / *total as f64 * 1000.0).round() / 10.0) }
        })
    };

    Ok(Json(MonitorResponse {
        checks: check_items,
        uptime_vpn: calc("vpn"),
        uptime_residential: calc("residential"),
        uptime_direct: calc("direct"),
    }))
}
