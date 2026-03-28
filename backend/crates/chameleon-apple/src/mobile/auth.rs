//! Mobile auth — Apple Sign In + device auth.
//! Returns proper HTTP status codes, validates input structure.

use axum::{http::StatusCode, routing::post, Json, Router};
use serde::Deserialize;
use chameleon_core::ChameleonCore;

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/auth/apple", post(apple_login))
        .route("/auth/refresh", post(refresh))
}

#[derive(Deserialize)]
struct AppleLoginRequest {
    identity_token: String,
    device_id: Option<String>,
}

#[derive(Deserialize)]
struct RefreshRequest {
    refresh_token: String,
}

async fn apple_login(
    Json(body): Json<AppleLoginRequest>,
) -> (StatusCode, Json<serde_json::Value>) {
    // Validate input present
    if body.identity_token.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "identity_token required"})));
    }
    if body.identity_token.len() > 4096 {
        return (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "identity_token too large"})));
    }
    // TODO: Apple JWKS verification, user creation
    (StatusCode::NOT_IMPLEMENTED, Json(serde_json::json!({"error": "Apple auth not yet implemented"})))
}

async fn refresh(
    Json(body): Json<RefreshRequest>,
) -> (StatusCode, Json<serde_json::Value>) {
    if body.refresh_token.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "refresh_token required"})));
    }
    // TODO: Mobile token refresh
    (StatusCode::NOT_IMPLEMENTED, Json(serde_json::json!({"error": "Mobile refresh not yet implemented"})))
}
