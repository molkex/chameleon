//! Background node metrics recorder — snapshots system + xray metrics every 5 minutes.
//! Writes to `node_metrics_history` table for dashboard charts.

use std::sync::Arc;
use std::time::Duration;
use sqlx::PgPool;
use tracing::{info, warn};

use chameleon_vpn::engine::ChameleonEngine;

/// Read system metrics from /proc (Linux only).
/// Returns (cpu_percent, ram_used_mb, ram_total_mb, disk_percent).
fn read_system_metrics() -> (Option<f64>, Option<f64>, Option<f64>, Option<f64>) {
    let cpu = read_cpu_usage();
    let (ram_used, ram_total) = read_memory();
    let disk = read_disk_usage();
    (cpu, ram_used, ram_total, disk)
}

fn read_cpu_usage() -> Option<f64> {
    let loadavg = std::fs::read_to_string("/host/proc/loadavg")
        .or_else(|_| std::fs::read_to_string("/proc/loadavg")).ok()?;
    let load: f64 = loadavg.split_whitespace().next()?.parse().ok()?;
    let cpus = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1) as f64;
    Some(((load / cpus) * 100.0).min(100.0).round())
}

fn read_memory() -> (Option<f64>, Option<f64>) {
    let meminfo = std::fs::read_to_string("/host/proc/meminfo")
        .or_else(|_| std::fs::read_to_string("/proc/meminfo")).ok();
    let meminfo = match meminfo {
        Some(m) => m,
        None => return (None, None),
    };

    let mut total_kb: f64 = 0.0;
    let mut available_kb: f64 = 0.0;

    for line in meminfo.lines() {
        if line.starts_with("MemTotal:") {
            total_kb = line.split_whitespace().nth(1)
                .and_then(|v| v.parse().ok()).unwrap_or(0.0);
        } else if line.starts_with("MemAvailable:") {
            available_kb = line.split_whitespace().nth(1)
                .and_then(|v| v.parse().ok()).unwrap_or(0.0);
        }
    }

    if total_kb > 0.0 {
        let total_mb = (total_kb / 1024.0).round();
        let used_mb = ((total_kb - available_kb) / 1024.0).round();
        (Some(used_mb), Some(total_mb))
    } else {
        (None, None)
    }
}

fn read_disk_usage() -> Option<f64> {
    let output = std::process::Command::new("df")
        .args(["--output=pcent", "/"])
        .output().ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let pct = stdout.lines().nth(1)?
        .trim().trim_end_matches('%')
        .parse::<f64>().ok()?;
    Some(pct)
}

/// Record a single metrics snapshot for all nodes.
pub async fn record_metrics_snapshot(
    pool: &PgPool,
    engine: &ChameleonEngine,
) {
    let servers = engine.build_server_configs();
    let (traffic_up, traffic_down) = engine.xray_api().query_total_traffic().await;
    let online_users = engine.xray_api().count_online_users().await;
    let (cpu, ram_used, ram_total, disk) = read_system_metrics();

    for srv in &servers {
        if let Err(e) = sqlx::query(
            "INSERT INTO node_metrics_history (node_key, cpu, ram_used, ram_total, disk, traffic_up, traffic_down, online_users)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)"
        )
        .bind(&srv.key)
        .bind(cpu.map(|v| v as f32))
        .bind(ram_used.map(|v| v as f32))
        .bind(ram_total.map(|v| v as f32))
        .bind(disk.map(|v| v as f32))
        .bind(traffic_up)
        .bind(traffic_down)
        .bind(online_users)
        .execute(pool)
        .await {
            warn!(node = srv.key, error = %e, "Failed to record metrics snapshot");
        }
    }
}

/// Run metrics recording loop (call via tokio::spawn).
/// Records a snapshot every 5 minutes into node_metrics_history.
pub async fn run_metrics_recorder(pool: PgPool, engine: Arc<ChameleonEngine>) {
    let interval = Duration::from_secs(5 * 60);
    info!("Node metrics recorder started (interval=5min)");

    loop {
        tokio::time::sleep(interval).await;
        record_metrics_snapshot(&pool, &engine).await;
    }
}
