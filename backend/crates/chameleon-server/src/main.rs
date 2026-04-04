//! Chameleon VPN — modular backend server.
//!
//! Modules enabled via Cargo features:
//!   --features admin  → Web admin panel API
//!   --features apple  → iOS/macOS app support
//!   --features full   → All modules
//!   (no features)     → Core only (/health endpoint)

use tokio::net::TcpListener;
use tracing::info;

use chameleon_config::get_settings;
use chameleon_core::ChameleonCore;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,sqlx=warn".into()),
        )
        .init();

    let settings = get_settings();
    let (errors, warnings) = settings.validate();
    for w in &warnings { tracing::warn!("Config: {w}"); }
    if !errors.is_empty() {
        for e in &errors { tracing::error!("Config error: {e}"); }
        anyhow::bail!("Configuration validation failed");
    }
    info!("Configuration loaded (env={})", settings.environment);

    // Initialize core
    let core = ChameleonCore::init(settings).await?;
    info!("ChameleonCore initialized");

    // Background: traffic collector
    let tc_db = core.db.clone();
    let tc_engine = core.engine.clone();
    tokio::spawn(async move {
        chameleon_monitoring::traffic_collector::run_traffic_collector(
            tc_db, tc_engine.xray_api(), 30,
        ).await;
    });

    // Background: node metrics recorder (every 5 min)
    {
        let mr_db = core.db.clone();
        let mr_engine = core.engine.clone();
        tokio::spawn(async move {
            chameleon_monitoring::metrics_recorder::run_metrics_recorder(mr_db, mr_engine).await;
        });
    }

    // Collect module routes
    let mut modules = vec![];

    #[cfg(feature = "admin")]
    {
        info!("Module: admin");
        modules.push(chameleon_admin::routes(core.clone()));
    }

    #[cfg(feature = "apple")]
    {
        info!("Module: apple");
        modules.push(chameleon_apple::routes(core.clone()));
    }

    #[cfg(feature = "cluster")]
    {
        info!("Module: cluster");
        modules.push(chameleon_cluster::routes());
        let cluster_core = core.clone();
        tokio::spawn(chameleon_cluster::sync::start_sync_loop(cluster_core));
    }

    // Build app
    let app = chameleon_core::build_app(core, modules);

    let addr = "0.0.0.0:8000";
    let listener = TcpListener::bind(addr).await?;
    info!("Listening on {addr}");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    info!("Shutdown complete");
    Ok(())
}

async fn shutdown_signal() {
    tokio::signal::ctrl_c().await.expect("CTRL+C handler");
    info!("Shutdown signal received");
}
