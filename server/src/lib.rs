pub mod api;
pub mod auth;
pub mod config;
pub mod db;
pub mod error;
pub mod extract;
pub mod hooks;
pub mod oidc;
pub mod ratelimit;
pub mod schedule;
pub mod state;
pub mod util;

use axum::{Router, extract::Request};
use tower_http::trace::TraceLayer;

use crate::state::AppState;

pub fn router(state: AppState) -> Router {
    Router::new()
        .nest("/api/v1", api::router())
        .merge(auth::router(state.clone()))
        .merge(hooks::router())
        .layer(TraceLayer::new_for_http().make_span_with(|request: &Request| {
            tracing::info_span!("request", method = %request.method(), path = loggable_path(request.uri().path()))
        }))
        .with_state(state)
}

/// The request path without anything secret: never the query string (it
/// carries authorization codes) and never a webhook secret.
fn loggable_path(path: &str) -> &str {
    if path.starts_with("/hook/") { "/hook/<secret>" } else { path }
}
