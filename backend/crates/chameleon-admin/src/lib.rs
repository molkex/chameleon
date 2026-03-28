//! Chameleon Admin Module — web admin panel API.
//! Optional module: compile with `--features admin` on chameleon-server.

mod admin;

use axum::Router;
use chameleon_core::ChameleonCore;

/// Admin module routes — nest under /api/v1/admin.
pub fn routes(core: ChameleonCore) -> Router<ChameleonCore> {
    let rate_limit = axum::middleware::from_fn_with_state(
        core,
        chameleon_core::middleware::rate_limit::auth_rate_limit,
    );

    Router::new()
        .nest("/api/v1/admin", admin::router().layer(rate_limit))
}
