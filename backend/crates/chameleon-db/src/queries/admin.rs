//! Admin user queries (admin_users table).

use sqlx::PgPool;

use crate::models::AdminUser;

/// Safely truncate a UTF-8 string to at most `max_bytes` without splitting characters.
fn truncate_utf8(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes { return s; }
    let mut end = max_bytes;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// Admin user without password_hash — safe for API responses.
#[derive(Debug, Clone, sqlx::FromRow, serde::Serialize)]
pub struct AdminUserSafe {
    pub id: i32,
    pub username: String,
    pub role: String,
    pub is_active: bool,
    pub last_login: Option<chrono::NaiveDateTime>,
    pub created_at: Option<chrono::NaiveDateTime>,
}

pub async fn find_admin_by_username(pool: &PgPool, username: &str) -> anyhow::Result<Option<AdminUser>> {
    let row = sqlx::query_as::<_, AdminUser>(
        "SELECT id, username, password_hash, role, is_active, last_login, created_at
         FROM admin_users WHERE username = $1"
    )
    .bind(username)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}

pub async fn list_admins(pool: &PgPool) -> anyhow::Result<Vec<AdminUserSafe>> {
    let rows = sqlx::query_as::<_, AdminUserSafe>(
        "SELECT id, username, role, is_active, last_login, created_at
         FROM admin_users ORDER BY id"
    )
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

pub async fn create_admin(
    pool: &PgPool,
    username: &str,
    password_hash: &str,
    role: &str,
) -> anyhow::Result<AdminUser> {
    let row = sqlx::query_as::<_, AdminUser>(
        "INSERT INTO admin_users (username, password_hash, role)
         VALUES ($1, $2, $3)
         RETURNING id, username, password_hash, role, is_active, last_login, created_at"
    )
    .bind(username)
    .bind(password_hash)
    .bind(role)
    .fetch_one(pool)
    .await?;
    Ok(row)
}

pub async fn delete_admin(pool: &PgPool, admin_id: i32) -> anyhow::Result<bool> {
    let result = sqlx::query("DELETE FROM admin_users WHERE id = $1")
        .bind(admin_id)
        .execute(pool)
        .await?;
    Ok(result.rows_affected() > 0)
}

pub async fn update_last_login(pool: &PgPool, admin_id: i32) -> anyhow::Result<()> {
    sqlx::query("UPDATE admin_users SET last_login = NOW() WHERE id = $1")
        .bind(admin_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn count_admins(pool: &PgPool) -> anyhow::Result<i64> {
    let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM admin_users")
        .fetch_one(pool)
        .await?;
    Ok(count.0)
}

pub async fn write_audit_log(
    pool: &PgPool,
    admin_user_id: Option<i32>,
    action: &str,
    ip: &str,
    user_agent: Option<&str>,
    details: Option<&str>,
) -> anyhow::Result<()> {
    sqlx::query(
        "INSERT INTO admin_audit_log (admin_user_id, action, ip, user_agent, details)
         VALUES ($1, $2, $3, $4, $5)"
    )
    .bind(admin_user_id)
    .bind(action)
    .bind(ip)
    .bind(user_agent.map(|s| truncate_utf8(s, 256)))
    .bind(details.map(|s| truncate_utf8(s, 512)))
    .execute(pool)
    .await?;
    Ok(())
}
