//! VPN user queries.

use chrono::{NaiveDateTime, Utc};
use sqlx::{PgPool, QueryBuilder, Postgres};

use crate::models::User;

pub struct UserListResult {
    pub users: Vec<User>,
    pub total: i64,
}

pub async fn list_users(
    pool: &PgPool,
    page: i64,
    page_size: i64,
    status: Option<&str>,
    search: Option<&str>,
) -> anyhow::Result<UserListResult> {
    let offset = (page - 1) * page_size;
    let now = Utc::now().naive_utc();

    // Build dynamic query
    let mut count_qb: QueryBuilder<Postgres> = QueryBuilder::new(
        "SELECT COUNT(*) FROM users WHERE vpn_uuid IS NOT NULL"
    );
    let mut qb: QueryBuilder<Postgres> = QueryBuilder::new(
        "SELECT * FROM users WHERE vpn_uuid IS NOT NULL"
    );

    // Status filter
    match status {
        Some("active") => {
            let clause = " AND is_active = true AND subscription_expiry > ";
            count_qb.push(clause);
            count_qb.push_bind(now);
            qb.push(clause);
            qb.push_bind(now);
        }
        Some("expired") => {
            let clause = " AND subscription_expiry <= ";
            count_qb.push(clause);
            count_qb.push_bind(now);
            qb.push(clause);
            qb.push_bind(now);
        }
        Some("inactive") => {
            count_qb.push(" AND is_active = false");
            qb.push(" AND is_active = false");
        }
        _ => {}
    }

    // Search filter (escape SQL LIKE wildcards)
    if let Some(s) = search {
        if !s.is_empty() {
            let safe = s.replace('%', r"\%").replace('_', r"\_");
            let pattern = format!("%{safe}%");
            count_qb.push(" AND (vpn_username ILIKE ");
            count_qb.push_bind(pattern.clone());
            count_qb.push(" OR full_name ILIKE ");
            count_qb.push_bind(pattern.clone());
            count_qb.push(" OR username ILIKE ");
            count_qb.push_bind(pattern.clone());
            count_qb.push(")");

            let pattern2 = format!("%{safe}%");
            qb.push(" AND (vpn_username ILIKE ");
            qb.push_bind(pattern2.clone());
            qb.push(" OR full_name ILIKE ");
            qb.push_bind(pattern2.clone());
            qb.push(" OR username ILIKE ");
            qb.push_bind(pattern2);
            qb.push(")");
        }
    }

    // Count
    let total: (i64,) = count_qb
        .build_query_as()
        .fetch_one(pool)
        .await?;

    // Fetch page
    qb.push(" ORDER BY created_at DESC LIMIT ");
    qb.push_bind(page_size);
    qb.push(" OFFSET ");
    qb.push_bind(offset);

    let users: Vec<User> = qb
        .build_query_as()
        .fetch_all(pool)
        .await?;

    Ok(UserListResult {
        users,
        total: total.0,
    })
}

pub async fn find_user_by_vpn_username(pool: &PgPool, username: &str) -> anyhow::Result<Option<User>> {
    let row = sqlx::query_as::<_, User>("SELECT * FROM users WHERE vpn_username = $1")
        .bind(username)
        .fetch_optional(pool)
        .await?;
    Ok(row)
}

pub async fn find_user_by_id(pool: &PgPool, id: i32) -> anyhow::Result<Option<User>> {
    let row = sqlx::query_as::<_, User>("SELECT * FROM users WHERE id = $1")
        .bind(id)
        .fetch_optional(pool)
        .await?;
    Ok(row)
}

pub async fn find_user_by_apple_id(pool: &PgPool, apple_id: &str) -> anyhow::Result<Option<User>> {
    let row = sqlx::query_as::<_, User>("SELECT * FROM users WHERE apple_id = $1")
        .bind(apple_id)
        .fetch_optional(pool)
        .await?;
    Ok(row)
}

pub async fn count_users(pool: &PgPool) -> anyhow::Result<i64> {
    let (count,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM users")
        .fetch_one(pool)
        .await?;
    Ok(count)
}

pub async fn count_active_users(pool: &PgPool) -> anyhow::Result<i64> {
    let (count,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM users WHERE is_active = true")
        .fetch_one(pool)
        .await?;
    Ok(count)
}
