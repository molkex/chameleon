//! Chameleon Cluster — mesh sync between autonomous nodes.
//! Each node runs full stack (API + DB + Xray) and syncs with peers.

pub mod routes;
pub mod sync;

use axum::Router;
use chameleon_core::ChameleonCore;

pub fn routes() -> Router<ChameleonCore> {
    Router::new().nest("/api/v1/cluster", routes::router())
}
