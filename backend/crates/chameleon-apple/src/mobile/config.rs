//! Mobile config endpoint — delivers sing-box JSON config for iOS/macOS.

use axum::{extract::{Query, State}, routing::get, Json, Router};
use chameleon_config::get_settings;
use chameleon_core::ChameleonCore;
use chameleon_vpn::protocols::{ProtocolRegistry, UserCredentials};
use chameleon_vpn::singbox;
use serde::Deserialize;

#[derive(Deserialize)]
struct ConfigQuery {
    username: Option<String>,
    mode: Option<String>,
}

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/config", get(get_config))
        .route("/servers", get(get_servers))
}

async fn get_config(
    State(core): State<ChameleonCore>,
    Query(q): Query<ConfigQuery>,
) -> Json<serde_json::Value> {
    let Some(username) = q.username.filter(|u| !u.is_empty()) else {
        return Json(serde_json::json!({"error": "username required"}));
    };

    let db_user = sqlx::query_as::<_, (Option<String>, Option<String>, Option<String>)>(
        "SELECT vpn_username, vpn_uuid, vpn_short_id FROM users WHERE vpn_username = $1 AND is_active = true"
    )
    .bind(&username)
    .fetch_optional(&core.db)
    .await
    .ok()
    .flatten();

    let Some((Some(vpn_username), Some(uuid), short_id)) = db_user else {
        return Json(serde_json::json!({"error": "User not found"}));
    };

    let settings = get_settings();
    let registry = ProtocolRegistry::new(settings);
    let creds = UserCredentials { username: vpn_username, uuid, short_id: short_id.unwrap_or_default() };
    let servers = core.engine.build_server_configs_from_db(&core.db).await;

    let config = singbox::generate_config(&registry, &creds, &servers);
    Json(config)
}

async fn get_servers(
    State(core): State<ChameleonCore>,
) -> Json<serde_json::Value> {
    let servers = core.engine.build_server_configs_from_db(&core.db).await;
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
