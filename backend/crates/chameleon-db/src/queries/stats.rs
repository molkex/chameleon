//! Dashboard statistics queries.

use chrono::{NaiveDateTime, Utc, Duration};
use sqlx::PgPool;

fn today_start() -> NaiveDateTime {
    Utc::now().naive_utc().date().and_hms_opt(0, 0, 0).unwrap()
}

pub struct DashboardCounts {
    pub total_users: i64,
    pub active_users: i64,
    pub blocked_users: i64,
    pub today_new: i64,
    pub proxy_clicks: i64,
}

pub async fn get_dashboard_counts(pool: &PgPool) -> anyhow::Result<DashboardCounts> {
    let today_start = today_start();

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
    let today_start = today_start();
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

pub struct TodayTransactionStats {
    pub today_transactions: i64,
    pub today_paid: i64,
}

pub async fn get_today_transaction_stats(pool: &PgPool) -> anyhow::Result<TodayTransactionStats> {
    let today_start = today_start();
    let (today_transactions, today_paid): (i64, i64) = sqlx::query_as(
        "SELECT
            COUNT(*),
            COALESCE(SUM(amount) FILTER (WHERE status = 'paid'), 0)::bigint
         FROM transactions
         WHERE created_at >= $1"
    )
    .bind(today_start)
    .fetch_one(pool)
    .await?;

    Ok(TodayTransactionStats { today_transactions, today_paid })
}

pub async fn get_conversion_30d(pool: &PgPool) -> anyhow::Result<f64> {
    let (conversion,): (Option<f64>,) = sqlx::query_as(
        "SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE original_transaction_id IS NOT NULL) / NULLIF(COUNT(*), 0), 1)::float8
         FROM users WHERE created_at >= NOW() - interval '30 days'"
    )
    .fetch_one(pool)
    .await?;

    Ok(conversion.unwrap_or(0.0))
}

pub async fn get_churned_7d(pool: &PgPool) -> anyhow::Result<i64> {
    let (churned,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM users
         WHERE subscription_expiry < NOW()
         AND subscription_expiry >= NOW() - interval '7 days'"
    )
    .fetch_one(pool)
    .await?;

    Ok(churned)
}

pub struct Rev7dPoint {
    pub label: String,
    pub total: f64,
}

pub async fn get_revenue_7d(pool: &PgPool) -> anyhow::Result<Vec<Rev7dPoint>> {
    let rows: Vec<(Option<String>, Option<f64>)> = sqlx::query_as(
        "SELECT to_char(d, 'DD.MM') as label, COALESCE(SUM(t.amount)::float8, 0.0)
         FROM generate_series(CURRENT_DATE - interval '6 days', CURRENT_DATE, '1 day') d
         LEFT JOIN transactions t ON t.created_at::date = d AND t.status = 'paid'
         GROUP BY d ORDER BY d"
    )
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(|(l, t)| Rev7dPoint {
        label: l.unwrap_or_default(),
        total: t.unwrap_or(0.0),
    }).collect())
}
