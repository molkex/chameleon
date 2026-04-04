//! Chameleon Core — the central VPN management facade.
//!
//! This crate provides `ChameleonCore` — a single struct that owns all shared
//! state (DB, Redis, VPN engine) and exposes business-logic methods.
//! Frontend modules (admin, apple, telegram) call these methods instead of
//! accessing DB/Redis directly.

pub mod error;
pub mod http_utils;
pub mod middleware;
pub mod settings_service;

use std::sync::Arc;

use axum::{
    extract::{DefaultBodyLimit, FromRef},
    routing::get,
    response::IntoResponse,
    http::{HeaderValue, Method},
    Json, Router,
};
use sqlx::PgPool;
use tower_http::cors::CorsLayer;

use chameleon_auth::AuthState;
use chameleon_config::Settings;
use chameleon_vpn::engine::ChameleonEngine;

pub use error::{ApiError, ApiResult};
pub use settings_service::SettingsService;

/// Central application state. Shared by all modules via axum State extractor.
#[derive(Clone)]
pub struct ChameleonCore {
    pub db: PgPool,
    pub redis: fred::clients::Pool,
    pub config: Arc<Settings>,
    pub engine: Arc<ChameleonEngine>,
    pub settings: SettingsService,
}

impl ChameleonCore {
    /// Initialize core from settings. Connects to DB, Redis, initializes VPN engine.
    pub async fn init(settings: &Settings) -> anyhow::Result<Self> {
        let db = chameleon_db::create_pool(&settings.database_url).await?;
        tracing::info!("PostgreSQL connected");

        use fred::prelude::ClientLike;
        let redis_config = fred::types::config::Config::from_url(&settings.redis_url)?;
        let redis = fred::clients::Pool::new(redis_config, None, None, None, 3)?;
        redis.init().await?;
        tracing::info!("Redis connected");

        let engine = ChameleonEngine::new(settings)
            .map_err(|e| anyhow::anyhow!("Engine init: {e}"))?;
        engine.init(&db).await;

        // Initialize settings service (DB-backed cache)
        let settings_svc = SettingsService::new(db.clone()).await;
        settings_svc.spawn_refresh_loop();
        tracing::info!("SettingsService initialized");

        Ok(Self {
            db,
            redis,
            config: Arc::new(settings.clone()),
            engine: Arc::new(engine),
            settings: settings_svc,
        })
    }
}

/// Core routes — /health and /sub (always available, no module needed).
pub fn core_routes() -> Router<ChameleonCore> {
    Router::new()
        .route("/health", get(health))
}

async fn health() -> impl IntoResponse {
    Json(serde_json::json!({"status": "ok"}))
}

/// Build the full router by merging core routes with module routes.
/// Modules pass their routers in; core adds shared middleware.
pub fn build_app(core: ChameleonCore, module_routes: Vec<Router<ChameleonCore>>) -> Router {
    let cors = if core.config.cors_origins.is_empty() {
        tracing::warn!("CORS_ORIGINS is not configured — using restrictive default (GET only, no credentials)");
        CorsLayer::new()
            .allow_methods([Method::GET])
    } else {
        CorsLayer::new()
            .allow_origin(
                core.config.cors_origins.iter()
                    .filter_map(|o| o.parse::<HeaderValue>().ok())
                    .collect::<Vec<_>>()
            )
            .allow_methods([Method::GET, Method::POST, Method::PATCH, Method::DELETE, Method::OPTIONS])
            .allow_headers([
                "content-type".parse().unwrap(),
                "authorization".parse().unwrap(),
                "cookie".parse().unwrap(),
            ])
            .allow_credentials(true)
    };

    let mut app = core_routes();
    for module in module_routes {
        app = app.merge(module);
    }

    app
        .layer(DefaultBodyLimit::max(1_048_576))
        .layer(axum::middleware::from_fn(middleware::security_headers::security_headers))
        .layer(cors)
        .with_state(core)
}

/// Allow admin auth extractors to get AuthState from ChameleonCore.
impl FromRef<ChameleonCore> for AuthState {
    fn from_ref(state: &ChameleonCore) -> Self {
        AuthState {
            jwt_secret: state.config.admin_jwt_secret.clone(),
            ip_allowlist: state.config.admin_ip_allowlist.clone(),
        }
    }
}

/// Allow mobile auth extractors to get MobileAuthState from ChameleonCore.
impl FromRef<ChameleonCore> for chameleon_auth::MobileAuthState {
    fn from_ref(state: &ChameleonCore) -> Self {
        chameleon_auth::MobileAuthState {
            jwt_secret: state.config.mobile_jwt_secret.clone(),
        }
    }
}
