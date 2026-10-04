use axum::{
    Json,
    extract::{FromRequest, FromRequestParts, Request, rejection::JsonRejection},
    http::{HeaderMap, Method, header, request::Parts},
};
use serde::de::DeserializeOwned;
use sqlx::Row;
use uuid::Uuid;

use crate::{
    error::ApiError,
    state::AppState,
    util::{now, sha256},
};

pub const SESSION_COOKIE: &str = "habitd_session";
pub const SESSION_LIFETIME: i64 = 30 * 24 * 3600;
/// `last_used_at` (and a session's expiry) is refreshed at most this often.
const TOUCH_INTERVAL: i64 = 60;

#[derive(Debug, Clone)]
pub struct User {
    pub id: Uuid,
    pub username: String,
    pub timezone: String,
    pub week_start: i64,
}

/// The authenticated user and the credential that made the request.
#[derive(Debug, Clone)]
pub struct AuthUser {
    pub user: User,
    pub token_id: Uuid,
}

pub fn session_cookie(headers: &HeaderMap) -> Option<&str> {
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(';'))
        .find_map(|pair| {
            let (name, value) = pair.trim().split_once('=')?;
            (name == SESSION_COOKIE).then_some(value)
        })
}

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let (token, via_cookie) = match parts.headers.get(header::AUTHORIZATION) {
            Some(value) => {
                let token = value
                    .to_str()
                    .ok()
                    .and_then(|v| v.strip_prefix("Bearer "))
                    .ok_or(ApiError::Unauthenticated)?;
                (token.trim(), false)
            }
            None => (session_cookie(&parts.headers).ok_or(ApiError::Unauthenticated)?, true),
        };

        let row = sqlx::query(
            "SELECT t.id AS token_id, t.kind, t.last_used_at, t.expires_at,
                    u.id, u.username, u.timezone, u.week_start
             FROM tokens t JOIN users u ON u.id = t.user_id
             WHERE t.token_hash = ?",
        )
        .bind(sha256(token.as_bytes()))
        .fetch_optional(&state.db)
        .await?
        .ok_or(ApiError::Unauthenticated)?;

        let now = now();
        let kind: String = row.get("kind");
        let expires_at: Option<i64> = row.get("expires_at");
        if expires_at.is_some_and(|at| at <= now) {
            return Err(ApiError::Unauthenticated);
        }

        if via_cookie {
            if kind != "session" {
                return Err(ApiError::Unauthenticated);
            }
            let safe = matches!(parts.method, Method::GET | Method::HEAD | Method::OPTIONS);
            if !safe {
                let origin = parts.headers.get(header::ORIGIN).and_then(|v| v.to_str().ok());
                if origin != Some(state.config.origin().as_str()) {
                    return Err(ApiError::Forbidden("origin not allowed".into()));
                }
            }
        }

        let token_id: Uuid = row.get("token_id");
        let last_used_at: Option<i64> = row.get("last_used_at");
        if last_used_at.is_none_or(|at| now - at >= TOUCH_INTERVAL) {
            let new_expiry =
                if kind == "session" { Some(now + SESSION_LIFETIME) } else { expires_at };
            sqlx::query("UPDATE tokens SET last_used_at = ?, expires_at = ? WHERE id = ?")
                .bind(now)
                .bind(new_expiry)
                .bind(token_id)
                .execute(&state.db)
                .await?;
        }

        Ok(AuthUser {
            user: User {
                id: row.get("id"),
                username: row.get("username"),
                timezone: row.get("timezone"),
                week_start: row.get("week_start"),
            },
            token_id,
        })
    }
}

/// `axum::Json` with rejections in the API's error format.
pub struct ApiJson<T>(pub T);

impl<S, T> FromRequest<S> for ApiJson<T>
where
    S: Send + Sync,
    T: DeserializeOwned,
{
    type Rejection = ApiError;

    async fn from_request(request: Request, state: &S) -> Result<Self, ApiError> {
        match Json::<T>::from_request(request, state).await {
            Ok(Json(value)) => Ok(Self(value)),
            Err(JsonRejection::JsonDataError(error)) => {
                Err(ApiError::Validation(error.body_text()))
            }
            Err(error) => Err(ApiError::BadRequest(error.body_text())),
        }
    }
}

/// Parses an ID from a path segment; anything that is not a UUID cannot exist.
pub fn parse_id(raw: &str) -> Result<Uuid, ApiError> {
    Uuid::parse_str(raw).map_err(|_| ApiError::NotFound)
}
