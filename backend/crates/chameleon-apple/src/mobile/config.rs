//! Mobile config endpoint — delivers sing-box JSON config for iOS/macOS.
//! All endpoints require MobileUser auth.

use axum::{extract::State, routing::get, Json, Router};
use chameleon_auth::MobileUser;
use chameleon_config::get_settings;
use chameleon_core::ChameleonCore;
use chameleon_vpn::protocols::{ProtocolRegistry, UserCredentials};
use chameleon_vpn::singbox;

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/config", get(get_config))
        .route("/servers", get(get_servers))
}

async fn get_config(
    State(core): State<ChameleonCore>,
    user: MobileUser,
) -> Json<serde_json::Value> {
    // Find user in DB
    let db_user = sqlx::query_as::<_, (Option<String>, Option<String>, Option<String>)>(
        "SELECT vpn_username, vpn_uuid, vpn_short_id FROM users WHERE id = $1"
    )
    .bind(user.user_id)
    .fetch_optional(&core.db)
    .await
    .ok()
    .flatten();

    let Some((Some(username), Some(uuid), short_id)) = db_user else {
        return Json(serde_json::json!({"error": "User not found"}));
    };

    let settings = get_settings();
    let registry = ProtocolRegistry::new(settings);
    let creds = UserCredentials { username, uuid, short_id: short_id.unwrap_or_default() };
    let servers = core.engine.build_server_configs();

    let config = singbox::generate_config(&registry, &creds, &servers);
    Json(config)
}

async fn get_servers(
    State(core): State<ChameleonCore>,
    _user: MobileUser,
) -> Json<serde_json::Value> {
    let servers = core.engine.build_server_configs();
    let list: Vec<serde_json::Value> = servers.iter().map(|s| {
        serde_json::json!({
            "key": s.key,
            "name": s.name,
            "flag": s.flag,
            "host": s.host,
        })
    }).collect();
    Json(serde_json::json!({"servers": list}))
}
