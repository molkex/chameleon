//! Device limiter — tracks unique devices (HWID/IP) per user via Redis.
//! Enforces per-user device limits to prevent account sharing.

use std::collections::HashMap;
use fred::prelude::*;
use tracing::{debug, warn};

const KEY_PREFIX: &str = "devices:";
const KEY_TTL: i64 = 86400; // 24h — stale devices expire

/// Record a device connection for a user. Returns current device count.
pub async fn record_device(
    redis: &fred::clients::Pool,
    username: &str,
    device_id: &str,
) -> anyhow::Result<usize> {
    let key = format!("{KEY_PREFIX}{username}");

    // SADD device_id to user's device set
    let _: i64 = redis.sadd(&key, device_id).await?;

    // Refresh TTL
    let _: bool = redis.expire(&key, KEY_TTL, None).await?;

    // Return current count
    let count: i64 = redis.scard(&key).await?;
    Ok(count as usize)
}

/// Get current device count for a user.
pub async fn get_device_count(
    redis: &fred::clients::Pool,
    username: &str,
) -> anyhow::Result<usize> {
    let key = format!("{KEY_PREFIX}{username}");
    let count: i64 = redis.scard(&key).await?;
    Ok(count as usize)
}

/// Get all device counts for multiple users.
pub async fn get_all_device_counts(
    redis: &fred::clients::Pool,
    usernames: &[String],
) -> HashMap<String, usize> {
    let mut result = HashMap::new();
    for username in usernames {
        if let Ok(count) = get_device_count(redis, username).await {
            if count > 0 {
                result.insert(username.clone(), count);
            }
        }
    }
    result
}

/// Check if a user has exceeded their device limit.
/// Returns (allowed, current_count, limit).
pub async fn check_device_limit(
    redis: &fred::clients::Pool,
    username: &str,
    device_id: &str,
    user_limit: Option<i32>,
    global_limit: i32,
) -> (bool, usize, i32) {
    let limit = user_limit.unwrap_or(global_limit);
    if limit <= 0 {
        // 0 or negative = unlimited
        return (true, 0, 0);
    }

    let count = match record_device(redis, username, device_id).await {
        Ok(c) => c,
        Err(e) => {
            warn!(username, error = %e, "Device limiter Redis error — allowing");
            return (true, 0, limit);
        }
    };

    let allowed = (count as i32) <= limit;
    if !allowed {
        debug!(username, count, limit, "Device limit exceeded");
    }

    (allowed, count, limit)
}

/// Get users exceeding their device limits.
pub async fn get_violations(
    redis: &fred::clients::Pool,
    users: &[(String, Option<i32>)], // (username, per-user limit)
    global_limit: i32,
) -> Vec<DeviceViolation> {
    let mut violations = vec![];
    for (username, user_limit) in users {
        let limit = user_limit.unwrap_or(global_limit);
        if limit <= 0 { continue; }

        if let Ok(count) = get_device_count(redis, username).await {
            if (count as i32) > limit {
                violations.push(DeviceViolation {
                    username: username.clone(),
                    count,
                    limit,
                });
            }
        }
    }
    violations
}

/// Remove all tracked devices for a user (e.g. on account deletion).
pub async fn clear_devices(
    redis: &fred::clients::Pool,
    username: &str,
) -> anyhow::Result<()> {
    let key = format!("{KEY_PREFIX}{username}");
    let _: i64 = redis.del(&key).await?;
    Ok(())
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct DeviceViolation {
    pub username: String,
    pub count: usize,
    pub limit: i32,
}
