//! In-memory settings cache backed by the `app_settings` DB table.
//!
//! Priority: DB value > .env value > hardcoded default.
//! The cache auto-refreshes every 30 seconds via a background task.

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use sqlx::PgPool;
use tracing::{info, warn};

/// Known setting keys that can be managed via the admin panel.
pub mod keys {
    pub const BRAND_NAME: &str = "brand_name";
    pub const PROFILE_TITLE: &str = "profile_title";
    pub const SUPPORT_URL: &str = "support_url";
    pub const SUPPORT_CHANNEL: &str = "support_channel";
    pub const WEB_PAGE_URL: &str = "web_page_url";
    pub const UPDATE_INTERVAL: &str = "update_interval";
    pub const BRAND_EMOJI: &str = "brand_emoji";
    pub const SUPPORT_EMOJI: &str = "support_emoji";
    pub const CHANNEL_EMOJI: &str = "channel_emoji";
    pub const VPN_SERVERS: &str = "vpn_servers";
    pub const REALITY_SNIS: &str = "reality_snis";
    pub const TRIAL_DAYS: &str = "trial_days";
}

#[derive(Clone)]
pub struct SettingsService {
    cache: Arc<RwLock<HashMap<String, String>>>,
    db: PgPool,
}

impl SettingsService {
    /// Create a new settings service and load initial values from DB.
    pub async fn new(db: PgPool) -> Self {
        let service = Self {
            cache: Arc::new(RwLock::new(HashMap::new())),
            db,
        };
        service.refresh().await;
        service
    }

    /// Refresh the in-memory cache from the database.
    pub async fn refresh(&self) {
        match chameleon_db::queries::settings::get_all(&self.db).await {
            Ok(rows) => {
                let mut map = HashMap::with_capacity(rows.len());
                for row in rows {
                    map.insert(row.key, row.value);
                }
                let count = map.len();
                *self.cache.write().await = map;
                tracing::debug!("Settings cache refreshed: {count} entries");
            }
            Err(e) => {
                warn!("Failed to refresh settings cache: {e}");
            }
        }
    }

    /// Get a setting value. Returns DB value if present, otherwise None.
    /// Caller should fall back to .env / default if None.
    pub async fn get(&self, key: &str) -> Option<String> {
        self.cache.read().await.get(key).cloned()
    }

    /// Get a setting with a fallback value (typically from .env/config).
    pub async fn get_or(&self, key: &str, fallback: &str) -> String {
        self.get(key).await.unwrap_or_else(|| fallback.to_string())
    }

    /// Get all cached settings as a HashMap snapshot.
    pub async fn get_all(&self) -> HashMap<String, String> {
        self.cache.read().await.clone()
    }

    /// Write a setting to DB and update the cache immediately.
    pub async fn set(&self, key: &str, value: &str) -> Result<(), sqlx::Error> {
        chameleon_db::queries::settings::upsert(&self.db, key, value).await?;
        self.cache.write().await.insert(key.to_string(), value.to_string());
        Ok(())
    }

    /// Write multiple settings to DB and update the cache.
    pub async fn set_many(&self, pairs: &[(&str, &str)]) -> Result<(), sqlx::Error> {
        chameleon_db::queries::settings::upsert_many(&self.db, pairs).await?;
        let mut cache = self.cache.write().await;
        for (k, v) in pairs {
            cache.insert(k.to_string(), v.to_string());
        }
        Ok(())
    }

    /// Spawn a background task that refreshes the cache every 30 seconds.
    pub fn spawn_refresh_loop(&self) {
        let svc = self.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(30));
            loop {
                interval.tick().await;
                svc.refresh().await;
            }
        });
        info!("Settings refresh loop started (30s interval)");
    }
}
