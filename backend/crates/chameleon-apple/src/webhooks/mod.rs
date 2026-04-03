//! Webhook handlers — /webhooks/*
//! App Store Server Notifications V2

mod appstore;

use axum::{routing::post, Router};
use chameleon_core::ChameleonCore;

pub fn router() -> Router<ChameleonCore> {
    Router::new().route("/appstore", post(appstore::handle_notification))
}
