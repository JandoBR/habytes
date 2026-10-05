//! Categories: named groups of habits that can be folded away.

use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::{
    error::{ApiError, ApiResult},
    extract::{ApiJson, AuthUser, parse_id},
    state::AppState,
    util::now,
};

fn validate_name(name: &str) -> ApiResult<String> {
    let name = name.trim();
    if !(1..=60).contains(&name.chars().count()) {
        return Err(ApiError::validation("name must be between 1 and 60 characters"));
    }
    Ok(name.to_string())
}

/// The user's categories, in order.
pub async fn all(db: &SqlitePool, user_id: Uuid) -> sqlx::Result<Vec<Value>> {
    let rows = sqlx::query(
        "SELECT id, name, position, collapsed FROM categories
         WHERE user_id = ? ORDER BY position, created_at, id",
    )
    .bind(user_id)
    .fetch_all(db)
    .await?;
    Ok(rows
        .iter()
        .map(|row| {
            json!({
                "id": row.get::<Uuid, _>("id"),
                "name": row.get::<String, _>("name"),
                "position": row.get::<i64, _>("position"),
                "collapsed": row.get::<bool, _>("collapsed"),
            })
        })
        .collect())
}

/// One of the user's categories; anyone else's ID is a 404.
async fn find(db: &SqlitePool, user_id: Uuid, raw_id: &str) -> ApiResult<Value> {
    let id = parse_id(raw_id)?;
    all(db, user_id)
        .await?
        .into_iter()
        .find(|category| category["id"] == json!(id))
        .ok_or(ApiError::NotFound)
}

pub async fn list(State(state): State<AppState>, auth: AuthUser) -> ApiResult<Json<Value>> {
    Ok(Json(json!(all(&state.db, auth.user.id).await?)))
}

#[derive(Deserialize)]
pub struct CreateCategory {
    name: String,
}

pub async fn create(
    State(state): State<AppState>,
    auth: AuthUser,
    ApiJson(body): ApiJson<CreateCategory>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let name = validate_name(&body.name)?;
    let id = Uuid::now_v7();
    // New categories go last.
    sqlx::query(
        "INSERT INTO categories (id, user_id, name, position, created_at)
         VALUES (?1, ?2, ?3,
                 (SELECT COALESCE(MAX(position) + 1, 0) FROM categories WHERE user_id = ?2), ?4)",
    )
    .bind(id)
    .bind(auth.user.id)
    .bind(&name)
    .bind(now())
    .execute(&state.db)
    .await?;
    Ok((StatusCode::CREATED, Json(find(&state.db, auth.user.id, &id.to_string()).await?)))
}

#[derive(Deserialize)]
pub struct PatchCategory {
    name: Option<String>,
    collapsed: Option<bool>,
}

pub async fn patch(
    State(state): State<AppState>,
    auth: AuthUser,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<PatchCategory>,
) -> ApiResult<Json<Value>> {
    find(&state.db, auth.user.id, &id).await?;
    let name = body.name.as_deref().map(validate_name).transpose()?;
    sqlx::query(
        "UPDATE categories SET name = COALESCE(?, name), collapsed = COALESCE(?, collapsed)
         WHERE id = ?",
    )
    .bind(name)
    .bind(body.collapsed)
    .bind(parse_id(&id)?)
    .execute(&state.db)
    .await?;
    Ok(Json(find(&state.db, auth.user.id, &id).await?))
}

/// Deletes a category. Its habits stay, without one.
pub async fn delete(
    State(state): State<AppState>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    find(&state.db, auth.user.id, &id).await?;
    sqlx::query("DELETE FROM categories WHERE id = ?")
        .bind(parse_id(&id)?)
        .execute(&state.db)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct Order {
    ids: Vec<Uuid>,
}

pub async fn order(
    State(state): State<AppState>,
    auth: AuthUser,
    ApiJson(body): ApiJson<Order>,
) -> ApiResult<Json<Value>> {
    let mut tx = state.db.begin().await?;
    let mut current: Vec<Uuid> = sqlx::query_scalar("SELECT id FROM categories WHERE user_id = ?")
        .bind(auth.user.id)
        .fetch_all(&mut *tx)
        .await?;
    let mut requested = body.ids.clone();
    current.sort();
    requested.sort();
    if current != requested {
        return Err(ApiError::validation("ids must list every category exactly once"));
    }
    for (position, id) in body.ids.iter().enumerate() {
        sqlx::query("UPDATE categories SET position = ? WHERE id = ?")
            .bind(position as i64)
            .bind(id)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(Json(json!({ "ids": body.ids })))
}
