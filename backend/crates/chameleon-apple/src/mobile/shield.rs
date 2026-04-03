//! ChameleonShield API — protocol priorities for the app (Redis-backed).

use axum::{extract::State, routing::get, Json, Router};
use chameleon_config::get_settings;
use chameleon_vpn::protocols::ProtocolRegistry;
use chameleon_core::ChameleonCore;
use fred::prelude::*;

const SHIELD_REDIS_KEY: &str = "shield:config";

pub fn router() -> Router<ChameleonCore> {
    Router::new().route("/shield", get(get_shield))
}

async fn get_shield(
    State(core): State<ChameleonCore>,
    _user: chameleon_auth::MobileUser,
) -> Json<serde_json::Value> {
    // Try to read dynamic config from Redis first
    if let Ok(Some(raw)) = core.redis.get::<Option<String>, _>(SHIELD_REDIS_KEY).await {
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) {
            return Json(value);
        }
    }

    // Fallback: build from enabled protocols
    let settings = get_settings();
    let registry = ProtocolRegistry::new(settings);
    let enabled: Vec<&str> = registry.enabled().iter().map(|p| p.name()).collect();
    let recommended = enabled.first().copied().unwrap_or("vless_reality");

    let mut protocols = serde_json::Map::new();
    for (i, name) in enabled.iter().enumerate() {
        protocols.insert(name.to_string(), serde_json::json!({
            "priority": i + 1,
            "weight": 100 - (i * 10),
            "status": "active",
        }));
    }

    Json(serde_json::json!({
        "protocols": protocols,
        "recommended": recommended,
        "fallback_order": enabled,
        "updated_at": chrono::Utc::now().timestamp(),
    }))
}
