use std::{net::SocketAddr, time::Duration};

use habitd::{config::Config, db, state::AppState};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,tower_http=debug".into()),
        )
        .init();

    let config_path = std::env::args()
        .nth(1)
        .or_else(|| std::env::var("HABITD_CONFIG").ok())
        .unwrap_or_else(|| "config.toml".into());
    let config = Config::load(&config_path)?;
    if !config.is_https() {
        tracing::warn!("public_url is not https; use this for local development only");
    }

    let pool = db::connect(&config.database_path).await?;
    let bind_address = config.bind_address;
    let state = AppState::new(pool, config)?;

    tokio::spawn(housekeeping(state.clone()));

    let listener = TcpListener::bind(bind_address).await?;
    tracing::info!("habitd {} listening on {bind_address}", env!("CARGO_PKG_VERSION"));
    axum::serve(
        listener,
        habitd::router(state).into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await?;
    Ok(())
}

/// Hourly cleanup of expired rows and rate-limit windows.
async fn housekeeping(state: AppState) {
    let mut interval = tokio::time::interval(Duration::from_secs(3600));
    loop {
        interval.tick().await;
        if let Err(error) = db::cleanup(&state.db).await {
            tracing::error!(%error, "cleanup failed");
        }
        state.auth_limiter.prune();
        state.hook_limiter.prune();
    }
}

async fn shutdown_signal() {
    use tokio::signal::unix::{SignalKind, signal};
    let mut terminate = signal(SignalKind::terminate()).expect("install SIGTERM handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = terminate.recv() => {}
    }
}
