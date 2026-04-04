//! Settings endpoints — DB-backed with .env fallback.
//! GET /settings/branding — read branding settings
//! PATCH /settings/branding — update branding settings

use axum::{extract::State, routing::get, Json, Router};
use serde::{Deserialize, Serialize};

use chameleon_auth::{AuthAdmin, RequireAdmin};
use chameleon_core::{ChameleonCore, error::ApiResult, settings_service::keys};

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/settings/branding", get(get_branding).patch(update_branding))
}

#[derive(Serialize, Deserialize, Clone, Default)]
struct BrandingSettings {
    brand_name: String,
    profile_title: String,
    support_url: String,
    support_channel: String,
    web_page_url: String,
    update_interval: String,
    brand_emoji: String,
    support_emoji: String,
    channel_emoji: String,
    trial_days: String,
    reality_snis: String,
    vpn_servers: String,
}

/// Defaults from .env / hardcoded fallback.
fn env_defaults(state: &ChameleonCore) -> BrandingSettings {
    BrandingSettings {
        brand_name: "Chameleon VPN".into(),
        profile_title: "Chameleon VPN".into(),
        support_url: String::new(),
        support_channel: String::new(),
        web_page_url: String::new(),
        update_interval: "12".into(),
        brand_emoji: String::new(),
        support_emoji: String::new(),
        channel_emoji: String::new(),
        trial_days: state.config.trial_days.to_string(),
        reality_snis: state.config.reality_snis.join(","),
        vpn_servers: state.config.vpn_servers_raw.clone(),
    }
}

/// Build current settings: DB values override .env defaults.
async fn load_merged(state: &ChameleonCore) -> BrandingSettings {
    let defaults = env_defaults(state);
    let svc = &state.settings;

    BrandingSettings {
        brand_name: svc.get_or(keys::BRAND_NAME, &defaults.brand_name).await,
        profile_title: svc.get_or(keys::PROFILE_TITLE, &defaults.profile_title).await,
        support_url: svc.get_or(keys::SUPPORT_URL, &defaults.support_url).await,
        support_channel: svc.get_or(keys::SUPPORT_CHANNEL, &defaults.support_channel).await,
        web_page_url: svc.get_or(keys::WEB_PAGE_URL, &defaults.web_page_url).await,
        update_interval: svc.get_or(keys::UPDATE_INTERVAL, &defaults.update_interval).await,
        brand_emoji: svc.get_or(keys::BRAND_EMOJI, &defaults.brand_emoji).await,
        support_emoji: svc.get_or(keys::SUPPORT_EMOJI, &defaults.support_emoji).await,
        channel_emoji: svc.get_or(keys::CHANNEL_EMOJI, &defaults.channel_emoji).await,
        trial_days: svc.get_or(keys::TRIAL_DAYS, &defaults.trial_days).await,
        reality_snis: svc.get_or(keys::REALITY_SNIS, &defaults.reality_snis).await,
        vpn_servers: svc.get_or(keys::VPN_SERVERS, &defaults.vpn_servers).await,
    }
}

async fn get_branding(
    State(state): State<ChameleonCore>,
    _admin: AuthAdmin,
) -> ApiResult<Json<serde_json::Value>> {
    let settings = load_merged(&state).await;
    let defaults = env_defaults(&state);
    Ok(Json(serde_json::json!({"settings": settings, "defaults": defaults})))
}

async fn update_branding(
    State(state): State<ChameleonCore>,
    _admin: RequireAdmin,
    Json(body): Json<serde_json::Value>,
) -> ApiResult<Json<serde_json::Value>> {
    // Collect fields to upsert
    let field_map: &[(&str, &str)] = &[
        ("brand_name", keys::BRAND_NAME),
        ("profile_title", keys::PROFILE_TITLE),
        ("support_url", keys::SUPPORT_URL),
        ("support_channel", keys::SUPPORT_CHANNEL),
        ("web_page_url", keys::WEB_PAGE_URL),
        ("update_interval", keys::UPDATE_INTERVAL),
        ("brand_emoji", keys::BRAND_EMOJI),
        ("support_emoji", keys::SUPPORT_EMOJI),
        ("channel_emoji", keys::CHANNEL_EMOJI),
        ("trial_days", keys::TRIAL_DAYS),
        ("reality_snis", keys::REALITY_SNIS),
        ("vpn_servers", keys::VPN_SERVERS),
    ];

    let mut pairs: Vec<(&str, String)> = Vec::new();
    for (json_field, db_key) in field_map {
        if let Some(v) = body.get(*json_field).and_then(|v| v.as_str()) {
            pairs.push((db_key, v.to_string()));
        }
    }

    if !pairs.is_empty() {
        let refs: Vec<(&str, &str)> = pairs.iter().map(|(k, v)| (*k, v.as_str())).collect();
        state.settings.set_many(&refs).await
            .map_err(|e| chameleon_core::error::ApiError::Internal(e.into()))?;
    }

    let settings = load_merged(&state).await;
    Ok(Json(serde_json::json!({"ok": true, "settings": settings})))
}
