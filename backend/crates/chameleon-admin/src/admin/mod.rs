//! Admin API routes — /api/v1/admin/*

pub mod auth;
pub mod stats;
pub mod users;
pub mod nodes;
pub mod protocols;
pub mod servers;
pub mod settings;
pub mod admins;
pub mod monitor;
pub mod shield;

use axum::Router;
use chameleon_core::ChameleonCore;

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .nest("/auth", auth::router())
        .merge(stats::router())
        .merge(users::router())
        .merge(nodes::router())
        .merge(protocols::router())
        .merge(servers::router())
        .merge(settings::router())
        .merge(admins::router())
        .merge(monitor::router())
        .merge(shield::router())
}
