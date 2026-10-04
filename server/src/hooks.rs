//! `/hook/{secret}`: per-habit webhooks for automations.

use axum::{
    Json, Router,
    extract::{Path, Query, State},
    routing::post,
};
use serde::Deserialize;
use serde_json::Value;
use sqlx::Row;
use uuid::Uuid;

use crate::{
    api::{
        entries::{apply_increment, apply_set, status, validate_delta},
        habits::Habit,
    },
    error::{ApiError, ApiResult},
    schedule::today_in,
    state::AppState,
};

pub fn router() -> Router<AppState> {
    Router::new().route("/hook/{secret}", post(hook))
}

#[derive(Deserialize)]
struct HookQuery {
    delta: Option<i64>,
}

async fn hook(
    State(state): State<AppState>,
    Path(secret): Path<String>,
    Query(query): Query<HookQuery>,
) -> ApiResult<Json<Value>> {
    // Secrets are 43 characters; anything much longer is not worth a lookup or a limiter slot.
    if secret.len() > 64 {
        return Err(ApiError::NotFound);
    }
    if !state.hook_limiter.check(&secret) {
        return Err(ApiError::RateLimited);
    }

    let habit: Habit = sqlx::query_as("SELECT * FROM habits WHERE webhook_secret = ?")
        .bind(&secret)
        .fetch_optional(&state.db)
        .await?
        .ok_or(ApiError::NotFound)?;
    let owner = sqlx::query("SELECT timezone, week_start FROM users WHERE id = ?")
        .bind(habit.user_id)
        .fetch_one(&state.db)
        .await?;
    let date = today_in(owner.get("timezone"));

    let mut tx = state.db.begin().await?;
    if habit.kind == "counter" {
        let delta = query.delta.unwrap_or(1);
        validate_delta(delta)?;
        apply_increment(&mut tx, &habit, date, Uuid::now_v7(), delta).await?;
    } else {
        apply_set(&mut tx, &habit, date, 1).await?;
    }
    let status = status(&mut tx, &habit, owner.get("week_start"), date).await?;
    tx.commit().await?;
    Ok(Json(status))
}
