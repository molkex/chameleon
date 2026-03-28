//! Mobile subscription endpoints — all require MobileUser auth.

use axum::{routing::{get, post}, Json, Router};
use chameleon_auth::MobileUser;
use chameleon_core::ChameleonCore;

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/subscription", get(get_status))
        .route("/subscription/verify", post(verify))
}

async fn get_status(_user: MobileUser) -> Json<serde_json::Value> {
    // TODO: return subscription status for authenticated user
    Json(serde_json::json!({"status": "none"}))
}

async fn verify(_user: MobileUser) -> Json<serde_json::Value> {
    // TODO: StoreKit 2 JWS verification
    Json(serde_json::json!({"error": "Not implemented"}))
}
