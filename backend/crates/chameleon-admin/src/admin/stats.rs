//! Dashboard & analytics stats endpoints.
//! GET /stats/dashboard — matches Python DashboardResponse shape exactly.

use axum::{extract::State, routing::get, Json, Router};
use chrono::{Utc, Duration, NaiveDateTime};
use serde::Serialize;

use chameleon_auth::AuthAdmin;
use chameleon_core::{ChameleonCore, error::ApiResult};

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/stats/dashboard", get(dashboard))
}

#[derive(Serialize)]
struct DashboardResponse {
    stats: DashboardStats,
    vpn: VpnStats,
    recent_transactions: Vec<RecentTransaction>,
    expiring_users: Vec<ExpiringUser>,
}

#[derive(Serialize)]
struct DashboardStats {
    total_users: i64,
    active_users: i64,
    reachable_users: i64,
    blocked_users: i64,
    today_new: i64,
    revenue_by_currency: serde_json::Value,
    today_revenue: serde_json::Value,
    today_transactions: i64,
    today_paid: i64,
    proxy_clicks: i64,
    conversion_30d: f64,
    churned_7d: i64,
    rev_7d_labels: Vec<String>,
    rev_7d_data: Vec<f64>,
}

#[derive(Serialize)]
struct VpnStats {
    vpn_users: i64,
    active_users: i64,
    bw_in_gb: f64,
    bw_out_gb: f64,
}

#[derive(Serialize)]
struct RecentTransaction {
    user_id: Option<i32>,
    amount: f64,
    currency: String,
    status: String,
    created_at_fmt: String,
}

#[derive(Serialize)]
struct ExpiringUser {
    username: String,
    expire_fmt: String,
}

async fn dashboard(
    State(state): State<ChameleonCore>,
    _admin: AuthAdmin,
) -> ApiResult<Json<DashboardResponse>> {
    let counts = chameleon_db::queries::stats::get_dashboard_counts(&state.db).await
        .map_err(|e| chameleon_core::error::ApiError::Internal(e))?;

    let revenue_all = chameleon_db::queries::stats::get_revenue_all(&state.db).await.unwrap_or_default();
    let revenue_today = chameleon_db::queries::stats::get_revenue_today(&state.db).await.unwrap_or_default();

    let rev_map: serde_json::Value = revenue_all.iter()
        .map(|r| (r.currency.clone(), serde_json::json!(r.total)))
        .collect::<serde_json::Map<String, serde_json::Value>>()
        .into();

    let today_map: serde_json::Value = revenue_today.iter()
        .map(|r| (r.currency.clone(), serde_json::json!(r.total)))
        .collect::<serde_json::Map<String, serde_json::Value>>()
        .into();

    // Recent transactions
    let recent: Vec<(Option<i32>, Option<f64>, Option<String>, Option<String>, Option<NaiveDateTime>)> = sqlx::query_as(
        "SELECT user_id, amount::float8, currency, status, created_at FROM transactions ORDER BY created_at DESC LIMIT 10"
    ).fetch_all(&state.db).await.unwrap_or_default();

    let recent_transactions: Vec<RecentTransaction> = recent.into_iter().map(|(uid, amt, cur, st, ts)| {
        RecentTransaction {
            user_id: uid,
            amount: amt.unwrap_or(0.0),
            currency: cur.unwrap_or_else(|| "RUB".into()),
            status: st.unwrap_or_default(),
            created_at_fmt: ts.map(|t| t.format("%d.%m %H:%M").to_string()).unwrap_or_default(),
        }
    }).collect();

    // Expiring users (within 3 days)
    let now = Utc::now().naive_utc();
    let soon = now + Duration::days(3);
    let expiring: Vec<(Option<String>, Option<NaiveDateTime>)> = sqlx::query_as(
        "SELECT vpn_username, subscription_expiry FROM users
         WHERE is_active = true AND vpn_uuid IS NOT NULL
         AND subscription_expiry IS NOT NULL AND subscription_expiry > $1 AND subscription_expiry < $2
         ORDER BY subscription_expiry LIMIT 8"
    ).bind(now).bind(soon).fetch_all(&state.db).await.unwrap_or_default();

    let expiring_users: Vec<ExpiringUser> = expiring.into_iter().filter_map(|(u, ts)| {
        Some(ExpiringUser {
            username: u?,
            expire_fmt: ts?.format("%d.%m %H:%M").to_string(),
        })
    }).collect();

    Ok(Json(DashboardResponse {
        stats: DashboardStats {
            total_users: counts.total_users,
            active_users: counts.active_users,
            reachable_users: counts.total_users - counts.blocked_users,
            blocked_users: counts.blocked_users,
            today_new: counts.today_new,
            revenue_by_currency: rev_map,
            today_revenue: today_map,
            today_transactions: 0,
            today_paid: 0,
            proxy_clicks: counts.proxy_clicks,
            conversion_30d: 0.0,
            churned_7d: 0,
            rev_7d_labels: vec![],
            rev_7d_data: vec![],
        },
        vpn: VpnStats { vpn_users: counts.active_users, active_users: counts.active_users, bw_in_gb: 0.0, bw_out_gb: 0.0 },
        recent_transactions,
        expiring_users,
    }))
}
