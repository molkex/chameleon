//! Protocol listing endpoint.
//! GET /protocols — returns {protocols: [{name, display_name, enabled}]}

use axum::{extract::State, routing::get, Json, Router};
use serde::Serialize;

use chameleon_auth::AuthAdmin;
use chameleon_vpn::protocols::ProtocolRegistry;
use chameleon_config::get_settings;
use chameleon_core::{ChameleonCore, error::ApiResult};

pub fn router() -> Router<ChameleonCore> {
    Router::new().route("/protocols", get(list_protocols))
}

#[derive(Serialize)]
struct ProtocolInfo {
    name: String,
    display_name: String,
    enabled: bool,
}

async fn list_protocols(
    _admin: AuthAdmin,
) -> ApiResult<Json<serde_json::Value>> {
    let settings = get_settings();
    let registry = ProtocolRegistry::new(settings);
    let protocols: Vec<ProtocolInfo> = registry.all().iter().map(|p| {
        ProtocolInfo {
            name: p.name().to_string(),
            display_name: p.display_name().to_string(),
            enabled: p.enabled(),
        }
    }).collect();
    Ok(Json(serde_json::json!({"protocols": protocols})))
}
