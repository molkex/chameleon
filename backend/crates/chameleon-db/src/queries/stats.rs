//! Dashboard statistics queries.

use chrono::{NaiveDateTime, Utc, Duration};
use sqlx::PgPool;

pub struct DashboardCounts {
    pub total_users: i64,
    pub active_users: i64,
    pub blocked_users: i64,
    pub today_new: i64,
    pub proxy_clicks: i64,
}

pub async fn get_dashboard_counts(pool: &PgPool) -> anyhow::Result<DashboardCounts> {
    let now = Utc::now().naive_utc();
    let today_start = now.date().and_hms_opt(0, 0, 0).unwrap();

    let (total, active, blocked, today_new): (i64, i64, i64, i64) = sqlx::query_as(
        "SELECT
            COUNT(*),
            COUNT(*) FILTER (WHERE is_active = true),
            COUNT(*) FILTER (WHERE bot_blocked_at IS NOT NULL),
            COUNT(*) FILTER (WHERE created_at >= $1)
         FROM users"
    )
    .bind(today_start)
    .fetch_one(pool).await?;

    let (proxy_clicks,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM proxy_clicks")
        .fetch_one(pool).await?;

    Ok(DashboardCounts {
        total_users: total,
        active_users: active,
        blocked_users: blocked,
        today_new,
        proxy_clicks,
    })
}

pub struct RevenueByCurrency {
    pub currency: String,
    pub total: f64,
}

pub async fn get_revenue_all(pool: &PgPool) -> anyhow::Result<Vec<RevenueByCurrency>> {
    let rows: Vec<(Option<String>, Option<f64>)> = sqlx::query_as(
        "SELECT currency, SUM(amount)::float8 FROM transactions WHERE status = 'paid' GROUP BY currency"
    )
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().filter_map(|(c, t)| {
        Some(RevenueByCurrency {
            currency: c?,
            total: t.unwrap_or(0.0),
        })
    }).collect())
}

pub async fn get_revenue_today(pool: &PgPool) -> anyhow::Result<Vec<RevenueByCurrency>> {
    let today_start = Utc::now().naive_utc().date().and_hms_opt(0, 0, 0).unwrap();
    let rows: Vec<(Option<String>, Option<f64>)> = sqlx::query_as(
        "SELECT currency, SUM(amount)::float8 FROM transactions
         WHERE status = 'paid' AND created_at >= $1 GROUP BY currency"
    )
    .bind(today_start)
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().filter_map(|(c, t)| {
        Some(RevenueByCurrency {
            currency: c?,
            total: t.unwrap_or(0.0),
        })
    }).collect())
}
