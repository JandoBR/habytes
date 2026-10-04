use axum::{Json, extract::State};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    error::{ApiError, ApiResult},
    extract::{ApiJson, AuthUser, User},
    state::AppState,
};

fn user_json(user: &User) -> Json<Value> {
    Json(json!({
        "id": user.id,
        "username": user.username,
        "timezone": user.timezone,
        "week_start": user.week_start,
    }))
}

pub async fn get(auth: AuthUser) -> Json<Value> {
    user_json(&auth.user)
}

#[derive(Deserialize)]
pub struct PatchMe {
    timezone: Option<String>,
    week_start: Option<i64>,
}

pub async fn patch(
    State(state): State<AppState>,
    auth: AuthUser,
    ApiJson(body): ApiJson<PatchMe>,
) -> ApiResult<Json<Value>> {
    let mut user = auth.user;
    if let Some(timezone) = body.timezone {
        timezone
            .parse::<chrono_tz::Tz>()
            .map_err(|_| ApiError::validation("timezone must be a valid IANA time zone name"))?;
        user.timezone = timezone;
    }
    if let Some(week_start) = body.week_start {
        if !(1..=7).contains(&week_start) {
            return Err(ApiError::validation("week_start must be between 1 and 7"));
        }
        user.week_start = week_start;
    }
    sqlx::query("UPDATE users SET timezone = ?, week_start = ? WHERE id = ?")
        .bind(&user.timezone)
        .bind(user.week_start)
        .bind(user.id)
        .execute(&state.db)
        .await?;
    Ok(user_json(&user))
}
