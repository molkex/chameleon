//! Background sync loop that pulls/pushes changes from/to cluster peers.

use std::time::Duration;

use chrono::NaiveDateTime;
use serde::Serialize;
use sqlx::PgPool;
use tracing::{info, warn};

use chameleon_core::ChameleonCore;

use crate::routes::{SyncResponse, SyncUser, get_changes_since_dt, upsert_users};

// ── Types ──

#[derive(Debug, Clone)]
pub struct Peer {
    pub node_id: String,
    pub url: String,
}

#[derive(Debug, Serialize)]
struct PushPayload {
    users: Vec<SyncUser>,
    node_id: String,
}

// ── Public entry point ──

/// Background task that syncs with all peers every 30 seconds.
pub async fn start_sync_loop(core: ChameleonCore) {
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    info!("Cluster sync loop started (interval=30s)");

    loop {
        interval.tick().await;

        if let Err(e) = sync_with_peers(&core).await {
            warn!(error = %e, "Sync cycle failed");
        }
    }
}

// ── Sync logic ──

async fn sync_with_peers(core: &ChameleonCore) -> anyhow::Result<()> {
    let peers = get_peers(&core.db).await?;
    if peers.is_empty() {
        return Ok(());
    }

    let secret = &core.config.cluster_secret;
    if secret.is_empty() {
        warn!("CLUSTER_SECRET not configured — skipping sync");
        return Ok(());
    }

    for peer in &peers {
        if let Err(e) = sync_with_peer(core, peer, secret).await {
            warn!(peer = %peer.url, node = %peer.node_id, error = %e, "Peer sync failed");
        }
    }

    Ok(())
}

async fn sync_with_peer(
    core: &ChameleonCore,
    peer: &Peer,
    secret: &str,
) -> anyhow::Result<()> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()?;

    let last_sync = get_last_sync(&core.db, &peer.node_id).await;
    let since_ts = last_sync
        .map(|dt| dt.and_utc().timestamp())
        .unwrap_or(0);

    // Pull changes from peer
    let resp = client
        .get(format!("{}/api/v1/cluster/sync", peer.url))
        .query(&[("since", since_ts.to_string())])
        .header("X-Cluster-Secret", secret)
        .send()
        .await?;

    if !resp.status().is_success() {
        anyhow::bail!("Peer returned status {}", resp.status());
    }

    let sync_resp: SyncResponse = resp.json().await?;
    let pulled = sync_resp.users.len();

    if !sync_resp.users.is_empty() {
        upsert_users(&core.db, &sync_resp.users).await?;
        info!(peer = %peer.node_id, pulled, "Pulled changes from peer");
    }

    // Push our changes to peer
    let since_dt = last_sync.unwrap_or_else(|| chrono::DateTime::UNIX_EPOCH.naive_utc());
    let our_changes = get_changes_since_dt(&core.db, since_dt).await?;
    let pushed = our_changes.len();

    if !our_changes.is_empty() {
        let push_resp = client
            .post(format!("{}/api/v1/cluster/sync", peer.url))
            .header("X-Cluster-Secret", secret)
            .json(&PushPayload {
                users: our_changes,
                node_id: core.config.node_id.clone(),
            })
            .send()
            .await?;

        if !push_resp.status().is_success() {
            warn!(
                peer = %peer.node_id,
                status = %push_resp.status(),
                "Push to peer failed"
            );
        } else {
            info!(peer = %peer.node_id, pushed, "Pushed changes to peer");
        }
    }

    // Update last_sync timestamp
    update_last_sync(&core.db, &peer.node_id).await;

    Ok(())
}

// ── DB helpers ──

async fn get_peers(db: &PgPool) -> anyhow::Result<Vec<Peer>> {
    let rows: Vec<(String, String)> =
        sqlx::query_as("SELECT node_id, url FROM cluster_peers WHERE is_active = true")
            .fetch_all(db)
            .await?;
    Ok(rows
        .into_iter()
        .map(|(node_id, url)| Peer { node_id, url })
        .collect())
}

async fn get_last_sync(db: &PgPool, node_id: &str) -> Option<NaiveDateTime> {
    sqlx::query_scalar("SELECT last_sync FROM cluster_peers WHERE node_id = $1")
        .bind(node_id)
        .fetch_optional(db)
        .await
        .ok()
        .flatten()
}

async fn update_last_sync(db: &PgPool, node_id: &str) {
    let _ = sqlx::query("UPDATE cluster_peers SET last_sync = NOW() WHERE node_id = $1")
        .bind(node_id)
        .execute(db)
        .await;
}
