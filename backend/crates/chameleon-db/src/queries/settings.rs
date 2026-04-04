//! Database queries for app_settings key-value store.

use sqlx::PgPool;
use crate::models::AppSetting;

/// Load all settings from the database.
pub async fn get_all(pool: &PgPool) -> Result<Vec<AppSetting>, sqlx::Error> {
    sqlx::query_as::<_, AppSetting>("SELECT key, value, updated_at FROM app_settings")
        .fetch_all(pool)
        .await
}

/// Get a single setting by key.
pub async fn get_by_key(pool: &PgPool, key: &str) -> Result<Option<AppSetting>, sqlx::Error> {
    sqlx::query_as::<_, AppSetting>(
        "SELECT key, value, updated_at FROM app_settings WHERE key = $1",
    )
    .bind(key)
    .fetch_optional(pool)
    .await
}

/// Upsert a setting (insert or update).
pub async fn upsert(pool: &PgPool, key: &str, value: &str) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO app_settings (key, value, updated_at)
         VALUES ($1, $2, NOW())
         ON CONFLICT (key) DO UPDATE SET value = $2, updated_at = NOW()",
    )
    .bind(key)
    .bind(value)
    .execute(pool)
    .await?;
    Ok(())
}

/// Upsert multiple settings in a single transaction.
pub async fn upsert_many(pool: &PgPool, settings: &[(&str, &str)]) -> Result<(), sqlx::Error> {
    let mut tx = pool.begin().await?;
    for (key, value) in settings {
        sqlx::query(
            "INSERT INTO app_settings (key, value, updated_at)
             VALUES ($1, $2, NOW())
             ON CONFLICT (key) DO UPDATE SET value = $2, updated_at = NOW()",
        )
        .bind(key)
        .bind(value)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await
}

/// Delete a setting by key.
pub async fn delete(pool: &PgPool, key: &str) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM app_settings WHERE key = $1")
        .bind(key)
        .execute(pool)
        .await?;
    Ok(())
}
