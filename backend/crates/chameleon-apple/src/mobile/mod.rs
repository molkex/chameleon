//! Mobile API routes — /api/v1/mobile/*

pub mod auth;
pub mod config;
pub mod shield;
pub mod subscription;
pub mod support;

use axum::Router;
use chameleon_core::ChameleonCore;

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .merge(auth::router())
        .merge(config::router())
        .merge(shield::router())
        .merge(subscription::router())
        .merge(support::router())
}
