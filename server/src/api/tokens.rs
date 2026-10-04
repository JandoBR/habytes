use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::Row;
use uuid::Uuid;

use crate::{
    auth::{insert_token, new_token},
    error::{ApiError, ApiResult},
    extract::{ApiJson, AuthUser, parse_id},
    state::AppState,
    util::{now, rfc3339},
};

pub async fn list(State(state): State<AppState>, auth: AuthUser) -> ApiResult<Json<Value>> {
    let rows = sqlx::query(
        "SELECT id, kind, name, created_at, last_used_at, expires_at FROM tokens
         WHERE user_id = ? AND (expires_at IS NULL OR expires_at > ?)
         ORDER BY created_at DESC, id DESC",
    )
    .bind(auth.user.id)
    .bind(now())
    .fetch_all(&state.db)
    .await?;
    let tokens: Vec<Value> = rows
        .iter()
        .map(|row| {
            let id: Uuid = row.get("id");
            json!({
                "id": id,
                "kind": row.get::<String, _>("kind"),
                "name": row.get::<String, _>("name"),
                "created_at": rfc3339(row.get("created_at")),
                "last_used_at": row.get::<Option<i64>, _>("last_used_at").map(rfc3339),
                "expires_at": row.get::<Option<i64>, _>("expires_at").map(rfc3339),
                "current": id == auth.token_id,
            })
        })
        .collect();
    Ok(Json(json!(tokens)))
}

#[derive(Deserialize)]
pub struct CreateToken {
    name: String,
    expires_in_days: Option<i64>,
}

pub async fn create(
    State(state): State<AppState>,
    auth: AuthUser,
    ApiJson(body): ApiJson<CreateToken>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let name = body.name.trim();
    if !(1..=100).contains(&name.chars().count()) {
        return Err(ApiError::validation("name must be between 1 and 100 characters"));
    }
    if body.expires_in_days.is_some_and(|days| !(1..=3650).contains(&days)) {
        return Err(ApiError::validation("expires_in_days must be between 1 and 3650"));
    }
    let created_at = now();
    let expires_at = body.expires_in_days.map(|days| created_at + days * 24 * 3600);
    let token = new_token();
    let id = insert_token(&state.db, auth.user.id, "api", name, &token, expires_at).await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "id": id,
            "kind": "api",
            "name": name,
            "created_at": rfc3339(created_at),
            "last_used_at": null,
            "expires_at": expires_at.map(rfc3339),
            "current": false,
            "token": token,
        })),
    ))
}

pub async fn revoke(
    State(state): State<AppState>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let result = sqlx::query("DELETE FROM tokens WHERE id = ? AND user_id = ?")
        .bind(parse_id(&id)?)
        .bind(auth.user.id)
        .execute(&state.db)
        .await?;
    if result.rows_affected() == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
}
