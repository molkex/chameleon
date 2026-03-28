//! Webhook handlers — /webhooks/*
//! TODO: AppStore Server Notifications v2

use axum::Router;
use chameleon_core::ChameleonCore;

pub fn router() -> Router<ChameleonCore> {
    Router::new()
    // TODO: .route("/appstore", post(appstore_notification))
}
