//! VPN server queries (vpn_servers table).

use sqlx::PgPool;

use crate::models::VpnServer;

/// List only active servers, ordered by sort_order.
pub async fn list_active(pool: &PgPool) -> anyhow::Result<Vec<VpnServer>> {
    let rows = sqlx::query_as::<_, VpnServer>(
        "SELECT id, key, name, flag, host, port, domain, sni, is_active, sort_order, created_at, updated_at
         FROM vpn_servers
         WHERE is_active = true
         ORDER BY sort_order, id"
    )
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

/// List all servers (including inactive), ordered by sort_order.
pub async fn list_all(pool: &PgPool) -> anyhow::Result<Vec<VpnServer>> {
    let rows = sqlx::query_as::<_, VpnServer>(
        "SELECT id, key, name, flag, host, port, domain, sni, is_active, sort_order, created_at, updated_at
         FROM vpn_servers
         ORDER BY sort_order, id"
    )
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

/// Create a new server.
pub async fn create(
    pool: &PgPool,
    key: &str,
    name: &str,
    flag: &str,
    host: &str,
    port: i32,
    domain: &str,
    sni: &str,
    is_active: bool,
    sort_order: i32,
) -> anyhow::Result<VpnServer> {
    let row = sqlx::query_as::<_, VpnServer>(
        "INSERT INTO vpn_servers (key, name, flag, host, port, domain, sni, is_active, sort_order)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
         RETURNING id, key, name, flag, host, port, domain, sni, is_active, sort_order, created_at, updated_at"
    )
    .bind(key)
    .bind(name)
    .bind(flag)
    .bind(host)
    .bind(port)
    .bind(domain)
    .bind(sni)
    .bind(is_active)
    .bind(sort_order)
    .fetch_one(pool)
    .await?;
    Ok(row)
}

/// Update an existing server by id.
pub async fn update(
    pool: &PgPool,
    id: i32,
    key: &str,
    name: &str,
    flag: &str,
    host: &str,
    port: i32,
    domain: &str,
    sni: &str,
    is_active: bool,
    sort_order: i32,
) -> anyhow::Result<Option<VpnServer>> {
    let row = sqlx::query_as::<_, VpnServer>(
        "UPDATE vpn_servers
         SET key = $2, name = $3, flag = $4, host = $5, port = $6,
             domain = $7, sni = $8, is_active = $9, sort_order = $10,
             updated_at = NOW()
         WHERE id = $1
         RETURNING id, key, name, flag, host, port, domain, sni, is_active, sort_order, created_at, updated_at"
    )
    .bind(id)
    .bind(key)
    .bind(name)
    .bind(flag)
    .bind(host)
    .bind(port)
    .bind(domain)
    .bind(sni)
    .bind(is_active)
    .bind(sort_order)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}

/// Delete a server by id. Returns true if deleted.
pub async fn delete(pool: &PgPool, id: i32) -> anyhow::Result<bool> {
    let result = sqlx::query("DELETE FROM vpn_servers WHERE id = $1")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(result.rows_affected() > 0)
}
