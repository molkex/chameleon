//! Chameleon Apple Module — iOS/macOS app support.
//! Mobile auth (Apple Sign In), StoreKit, config delivery, subscriptions.

mod mobile;
mod subscription;
mod webhooks;

use axum::Router;
use chameleon_core::ChameleonCore;

/// Apple module routes.
pub fn routes() -> Router<ChameleonCore> {
    Router::new()
        .nest("/api/v1/mobile", mobile::router())
        .nest("/sub", subscription::router())
        .nest("/webhooks", webhooks::router())
}
