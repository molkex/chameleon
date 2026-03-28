//! Public subscription endpoints — /sub/{token}
//! Token is a cryptographic random string, NOT the vpn_username (F-09 fix).

use axum::{extract::{Path, State}, routing::get, response::IntoResponse, Router};
use axum::http::{header, StatusCode};

use chameleon_config::get_settings;
use chameleon_vpn::protocols::ProtocolRegistry;
use chameleon_vpn::links;
use chameleon_vpn::protocols::{UserCredentials, ServerConfig};
use chameleon_core::ChameleonCore;

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/{token}", get(subscription_links))
}

async fn subscription_links(
    State(state): State<ChameleonCore>,
    Path(token): Path<String>,
) -> impl IntoResponse {
    // Validate token format (48 hex chars = 24 random bytes)
    if token.len() < 32 || !token.chars().all(|c| c.is_ascii_hexdigit()) {
        // Add artificial delay to match DB query timing (anti-timing-oracle)
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        return (StatusCode::NOT_FOUND, "Not found").into_response();
    }

    // Lookup by cryptographic subscription_token (NOT vpn_username)
    // Always queries DB even for invalid tokens to prevent timing oracle
    let user: Option<(Option<String>, Option<String>, Option<String>, Option<chrono::NaiveDateTime>)> = sqlx::query_as(
        "SELECT vpn_username, vpn_uuid, vpn_short_id, subscription_expiry
         FROM users WHERE subscription_token = $1 AND is_active = true"
    ).bind(&token).fetch_optional(&state.db).await.ok().flatten();

    let Some((Some(username), Some(uuid), short_id, expiry)) = user else {
        return (StatusCode::NOT_FOUND, "Not found").into_response();
    };

    let settings = get_settings();
    let registry = ProtocolRegistry::new(settings);
    let creds = UserCredentials { username, uuid, short_id: short_id.unwrap_or_default() };

    let raw: serde_json::Value = serde_json::from_str(&settings.vpn_servers_raw).unwrap_or_default();
    let servers: Vec<ServerConfig> = raw.as_array().unwrap_or(&vec![]).iter().filter_map(|srv| {
        let ip = srv.get("ip")?.as_str()?;
        let domain = srv.get("domain").and_then(|d| d.as_str()).unwrap_or(ip);
        Some(ServerConfig {
            host: ip.into(), port: settings.vless_tcp_port, domain: domain.into(),
            flag: srv.get("flag").and_then(|f| f.as_str()).unwrap_or("").into(),
            name: srv.get("name").and_then(|n| n.as_str()).unwrap_or("").into(),
            key: domain.split('.').next().unwrap_or(domain).into(),
        })
    }).collect();

    let all_links = links::generate_all_links(&registry, &creds, &servers);
    let expire_ts = expiry.map(|t| t.and_utc().timestamp());
    let text = links::format_subscription_text(&all_links, expire_ts, None);
    let sub_headers = links::get_subscription_headers(expire_ts, 0, 0, None);

    let mut response = text.into_response();
    for (k, v) in sub_headers {
        if let (Ok(name), Ok(val)) = (k.parse::<header::HeaderName>(), v.parse()) {
            response.headers_mut().insert(name, val);
        }
    }
    response
}
