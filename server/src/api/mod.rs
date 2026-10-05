//! `/api/v1/*`: the JSON API.

use axum::{
    Json, Router,
    routing::{delete, get, patch, post, put},
};
use serde_json::{Value, json};

use crate::{error::ApiError, state::AppState};

pub mod categories;
pub mod entries;
pub mod habits;
mod me;
mod tokens;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/meta", get(meta))
        .route("/me", get(me::get).patch(me::patch))
        .route("/habits", get(habits::list).post(habits::create))
        .route("/habits/order", put(habits::order))
        .route("/habits/{id}", get(habits::get).patch(habits::patch).delete(habits::delete))
        .route("/habits/{id}/webhook", post(habits::create_webhook).delete(habits::delete_webhook))
        .route("/habits/{id}/entries/{date}", put(entries::set))
        .route("/habits/{id}/entries/{date}/increment", post(entries::increment))
        .route("/categories", get(categories::list).post(categories::create))
        .route("/categories/order", put(categories::order))
        .route("/categories/{id}", patch(categories::patch).delete(categories::delete))
        .route("/today", get(entries::today))
        .route("/entries", get(entries::list))
        .route("/tokens", get(tokens::list).post(tokens::create))
        .route("/tokens/{id}", delete(tokens::revoke))
        .fallback(|| async { ApiError::NotFound })
}

async fn meta() -> Json<Value> {
    Json(json!({ "name": "habitd", "version": env!("CARGO_PKG_VERSION"), "api_version": 1 }))
}
