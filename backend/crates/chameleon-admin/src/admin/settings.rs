//! Branding & settings endpoints.
//! GET /settings/branding, PATCH /settings/branding

use axum::{extract::State, routing::{get, patch}, Json, Router};
use serde::{Deserialize, Serialize};
use fred::prelude::*;

use chameleon_auth::{AuthAdmin, RequireAdmin};
use chameleon_core::{ChameleonCore, error::{ApiError, ApiResult}};

const REDIS_KEY: &str = "branding:settings";

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/settings/branding", get(get_branding).patch(update_branding))
}

#[derive(Serialize, Deserialize, Clone)]
struct BrandingSettings {
    profile_title: String,
    support_url: String,
    support_channel: String,
    web_page_url: String,
    update_interval: String,
    brand_name: String,
    brand_emoji: String,
    support_emoji: String,
    channel_emoji: String,
}

impl Default for BrandingSettings {
    fn default() -> Self {
        Self {
            profile_title: "Chameleon VPN".into(),
            support_url: String::new(),
            support_channel: String::new(),
            web_page_url: String::new(),
            update_interval: "12".into(),
            brand_name: "Chameleon VPN".into(),
            brand_emoji: String::new(),
            support_emoji: String::new(),
            channel_emoji: String::new(),
        }
    }
}

async fn get_branding(
    State(state): State<ChameleonCore>,
    _admin: AuthAdmin,
) -> ApiResult<Json<serde_json::Value>> {
    let defaults = BrandingSettings::default();
    let settings = load_branding(&state).await;
    Ok(Json(serde_json::json!({"settings": settings, "defaults": defaults})))
}

async fn update_branding(
    State(state): State<ChameleonCore>,
    _admin: RequireAdmin,
    Json(body): Json<serde_json::Value>,
) -> ApiResult<Json<serde_json::Value>> {
    let mut current = load_branding(&state).await;

    // Update only provided fields
    if let Some(v) = body.get("brand_name").and_then(|v| v.as_str()) { current.brand_name = v.into(); }
    if let Some(v) = body.get("profile_title").and_then(|v| v.as_str()) { current.profile_title = v.into(); }
    if let Some(v) = body.get("support_url").and_then(|v| v.as_str()) { current.support_url = v.into(); }
    if let Some(v) = body.get("support_channel").and_then(|v| v.as_str()) { current.support_channel = v.into(); }
    if let Some(v) = body.get("web_page_url").and_then(|v| v.as_str()) { current.web_page_url = v.into(); }
    if let Some(v) = body.get("update_interval").and_then(|v| v.as_str()) { current.update_interval = v.into(); }

    save_branding(&state, &current).await?;
    Ok(Json(serde_json::json!({"ok": true, "settings": current})))
}

async fn load_branding(state: &ChameleonCore) -> BrandingSettings {
    let result: Result<Option<String>, _> = state.redis.get(REDIS_KEY).await;
    match result {
        Ok(Some(data)) => serde_json::from_str(&data).unwrap_or_default(),
        _ => BrandingSettings::default(),
    }
}

async fn save_branding(state: &ChameleonCore, settings: &BrandingSettings) -> ApiResult<()> {
    let json = serde_json::to_string(settings).map_err(|e| ApiError::Internal(e.into()))?;
    let _: () = state.redis.set(REDIS_KEY, json, None, None, false).await
        .map_err(|e| ApiError::Internal(e.into()))?;
    Ok(())
}
