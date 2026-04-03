//! Chameleon Apple Module — iOS/macOS app support.
//! Mobile auth (Apple Sign In), StoreKit, config delivery, subscriptions.

mod mobile;
mod subscription;
mod webhooks;

use axum::Router;
use chameleon_core::ChameleonCore;

/// Apple module routes.
pub fn routes(core: ChameleonCore) -> Router<ChameleonCore> {
    Router::new()
        .nest("/api/v1/mobile", mobile::router())
        .nest("/api/mobile", mobile::router())  // Legacy path for existing iOS clients
        .nest("/sub", subscription::router(core))
        .nest("/webhooks", webhooks::router())
}
