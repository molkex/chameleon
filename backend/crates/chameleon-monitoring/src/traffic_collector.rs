//! Background traffic collector — periodically queries xray stats and flushes to DB.
//! Port of Python traffic_collector.py.

use std::collections::HashMap;
use std::time::Duration;
use chrono::Utc;
use sqlx::PgPool;
use tracing::{info, warn, debug};

use chameleon_vpn::xray_api::{XrayApi, TrafficStats};

/// Run traffic collection loop (call via tokio::spawn).
/// Collects xray user traffic every `interval` seconds and writes to DB.
pub async fn run_traffic_collector(
    pool: PgPool,
    xray_api: &XrayApi,
    interval_secs: u64,
) {
    let interval = Duration::from_secs(interval_secs);
    info!(interval_secs, "Traffic collector started");

    loop {
        tokio::time::sleep(interval).await;

        match collect_and_flush(&pool, xray_api).await {
            Ok(count) => {
                if count > 0 {
                    debug!(users = count, "Traffic flushed to DB");
                }
            }
            Err(e) => warn!(error = %e, "Traffic collection failed"),
        }
    }
}

async fn collect_and_flush(pool: &PgPool, xray_api: &XrayApi) -> anyhow::Result<usize> {
    let traffic = xray_api.query_all_traffic().await;
    if traffic.is_empty() {
        return Ok(0);
    }

    let now = Utc::now().naive_utc();
    let mut count = 0usize;

    for (username, stats) in &traffic {
        if stats.up == 0 && stats.down == 0 {
            continue;
        }

        // Update cumulative traffic on user record
        sqlx::query(
            "UPDATE users SET cumulative_traffic = COALESCE(cumulative_traffic, 0) + $1
             WHERE vpn_username = $2"
        )
        .bind(stats.up + stats.down)
        .bind(username)
        .execute(pool)
        .await?;

        // Insert traffic snapshot for history
        sqlx::query(
            "INSERT INTO traffic_snapshots (vpn_username, used_traffic, download_traffic, upload_traffic, timestamp)
             VALUES ($1, $2, $3, $4, $5)"
        )
        .bind(username)
        .bind(stats.up + stats.down)
        .bind(stats.down)
        .bind(stats.up)
        .bind(now)
        .execute(pool)
        .await?;

        count += 1;
    }

    Ok(count)
}

/// Write traffic stats to Redis cache for fast reads.
pub async fn cache_traffic_to_redis(
    redis: &fred::clients::Pool,
    traffic: &HashMap<String, TrafficStats>,
) {
    use fred::prelude::*;
    for (username, stats) in traffic {
        let key = format!("traffic:{username}");
        let _: Result<(), _> = redis.hset::<(), _, _>(
            &key,
            [("up", stats.up.to_string()), ("down", stats.down.to_string())],
        ).await;
    }
}
