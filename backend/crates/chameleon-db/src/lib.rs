//! Database layer — PgPool creation, models, and query modules.

pub mod models;
pub mod queries;

use std::time::Duration;
use sqlx::postgres::{PgPool, PgPoolOptions};
use tracing::info;

/// Create a connection pool and run pending migrations.
pub async fn create_pool(database_url: &str) -> anyhow::Result<PgPool> {
    let pool = PgPoolOptions::new()
        .max_connections(10)
        .min_connections(2)
        .acquire_timeout(Duration::from_secs(5))
        .idle_timeout(Duration::from_secs(300))
        .max_lifetime(Duration::from_secs(1800))
        .connect(database_url)
        .await?;

    info!("Database connected, running migrations...");
    sqlx::migrate!("../../migrations").run(&pool).await?;
    info!("Migrations complete");

    Ok(pool)
}
