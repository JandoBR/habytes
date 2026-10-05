//! `/auth/*`: OIDC login for the web and the Android app, token exchange, logout.

use std::net::{IpAddr, SocketAddr};

use axum::{
    Router,
    extract::{ConnectInfo, Query, Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{Html, IntoResponse, Redirect, Response},
    routing::{get, post},
};
use serde::Deserialize;
use serde_json::json;
use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::{
    error::{ApiError, ApiResult},
    extract::{ApiJson, AuthUser, SESSION_COOKIE, SESSION_LIFETIME, session_cookie},
    state::AppState,
    util::{now, pkce_s256, random_secret, sha256},
};

/// How long the user has to complete the provider's login page.
const FLOW_LIFETIME: i64 = 10 * 60;
/// How long the app has to redeem its one-time code.
const APP_CODE_LIFETIME: i64 = 60;
/// Browsers cap cookie lifetimes around here; the server-side expiry is what counts.
const COOKIE_MAX_AGE: i64 = 400 * 24 * 3600;

pub fn router(state: AppState) -> Router<AppState> {
    Router::new()
        .route("/auth/login", get(login))
        .route("/auth/callback", get(callback))
        .route("/auth/token", post(token))
        .route("/auth/logout", post(logout))
        .layer(middleware::from_fn_with_state(state, rate_limit))
}

fn client_ip(state: &AppState, request: &Request) -> IpAddr {
    if state.config.trust_forwarded_for {
        // The right-most entry is the one appended by our own proxy.
        let forwarded = request
            .headers()
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.rsplit(',').next())
            .and_then(|v| v.trim().parse().ok());
        if let Some(ip) = forwarded {
            return ip;
        }
    }
    request
        .extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|info| info.0.ip())
        .unwrap_or(IpAddr::from([0, 0, 0, 0]))
}

async fn rate_limit(State(state): State<AppState>, request: Request, next: Next) -> Response {
    if !state.auth_limiter.check(&client_ip(&state, &request).to_string()) {
        return ApiError::RateLimited.into_response();
    }
    next.run(request).await
}

pub fn new_token() -> String {
    format!("hbt_{}", random_secret())
}

/// Stores a new credential and returns its ID.
pub async fn insert_token(
    db: &SqlitePool,
    user_id: Uuid,
    kind: &str,
    name: &str,
    token: &str,
    expires_at: Option<i64>,
) -> sqlx::Result<Uuid> {
    let id = Uuid::now_v7();
    sqlx::query(
        "INSERT INTO tokens (id, user_id, kind, name, token_hash, created_at, expires_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(id)
    .bind(user_id)
    .bind(kind)
    .bind(name)
    .bind(sha256(token.as_bytes()))
    .bind(now())
    .bind(expires_at)
    .execute(db)
    .await?;
    Ok(id)
}

fn cookie(state: &AppState, value: &str, max_age: i64) -> HeaderValue {
    let secure = if state.config.is_https() { "; Secure" } else { "" };
    let cookie = format!(
        "{SESSION_COOKIE}={value}; Path=/; HttpOnly; SameSite=Lax; Max-Age={max_age}{secure}"
    );
    HeaderValue::from_str(&cookie).expect("cookie is ASCII")
}

/// A browser-facing failure page for the login redirects.
fn login_failed(message: &str) -> Response {
    let page = format!(
        "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'>\
         <title>Sign-in failed</title><body style='font-family:sans-serif;margin:3rem auto;max-width:28rem'>\
         <h1>Sign-in failed</h1><p>{message}</p><p><a href='/auth/login'>Try again</a></p>"
    );
    (StatusCode::BAD_REQUEST, Html(page)).into_response()
}

/// A local path: one leading slash, so it cannot point at another origin.
fn is_safe_redirect(path: &str) -> bool {
    path.starts_with('/')
        && !path.starts_with("//")
        && !path.starts_with("/\\")
        && !path.chars().any(|c| c.is_control())
}

fn is_pkce_challenge(value: &str) -> bool {
    value.len() == 43 && value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

#[derive(Deserialize)]
struct LoginQuery {
    redirect: Option<String>,
    client: Option<String>,
    code_challenge: Option<String>,
}

async fn login(
    State(state): State<AppState>,
    Query(query): Query<LoginQuery>,
) -> ApiResult<Response> {
    let (client, redirect_path, app_challenge) = match query.client.as_deref() {
        None | Some("web") => {
            let redirect = query.redirect.unwrap_or_else(|| "/".into());
            if !is_safe_redirect(&redirect) {
                return Err(ApiError::bad_request(
                    "redirect must be a path starting with a single /",
                ));
            }
            ("web", Some(redirect), None)
        }
        Some("app") => {
            let challenge = query
                .code_challenge
                .filter(|c| is_pkce_challenge(c))
                .ok_or_else(|| ApiError::bad_request("code_challenge must be an S256 challenge"))?;
            ("app", None, Some(challenge))
        }
        Some(_) => return Err(ApiError::bad_request("unknown client")),
    };

    let start = state.oidc.begin().await.map_err(ApiError::Internal)?;
    sqlx::query(
        "INSERT INTO login_flows (state, nonce, pkce_verifier, client, redirect_path, app_challenge, expires_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(&start.state)
    .bind(&start.nonce)
    .bind(&start.pkce_verifier)
    .bind(client)
    .bind(redirect_path)
    .bind(app_challenge)
    .bind(now() + FLOW_LIFETIME)
    .execute(&state.db)
    .await?;

    Ok(Redirect::to(&start.url).into_response())
}

#[derive(Deserialize)]
struct CallbackQuery {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
}

/// `Firefox on Linux`: who a session belongs to, in words, from its User-Agent.
fn describe_browser(user_agent: &str) -> String {
    // Most browsers also claim to be the ones they descend from, so the more
    // specific names are looked for first.
    let browsers = [
        ("Firefox/", "Firefox"),
        ("Edg/", "Edge"),
        ("OPR/", "Opera"),
        ("Vivaldi/", "Vivaldi"),
        ("Chrome/", "Chrome"),
        ("Safari/", "Safari"),
    ];
    let systems = [
        ("Android", "Android"),
        ("iPhone", "iPhone"),
        ("iPad", "iPad"),
        ("Windows", "Windows"),
        ("Mac OS X", "macOS"),
        ("Linux", "Linux"),
    ];
    let find = |names: &[(&str, &'static str)]| {
        names.iter().find(|(mark, _)| user_agent.contains(mark)).map(|&(_, name)| name)
    };
    match (find(&browsers), find(&systems)) {
        (Some(browser), Some(system)) => format!("{browser} on {system}"),
        (Some(name), None) | (None, Some(name)) => name.to_string(),
        (None, None) => "Web session".to_string(),
    }
}

async fn callback(
    State(state): State<AppState>,
    Query(query): Query<CallbackQuery>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    let Some(flow_state) = query.state else {
        return Ok(login_failed("The sign-in response was incomplete."));
    };
    let flow = sqlx::query(
        "SELECT nonce, pkce_verifier, client, redirect_path FROM login_flows
         WHERE state = ? AND expires_at > ? AND app_code_hash IS NULL",
    )
    .bind(&flow_state)
    .bind(now())
    .fetch_optional(&state.db)
    .await?;
    let Some(flow) = flow else {
        return Ok(login_failed("This sign-in attempt has expired."));
    };

    let delete_flow = || async {
        sqlx::query("DELETE FROM login_flows WHERE state = ?")
            .bind(&flow_state)
            .execute(&state.db)
            .await
    };

    let Some(code) = query.code else {
        delete_flow().await?;
        tracing::warn!(
            error = query.error.as_deref().unwrap_or("none"),
            "provider refused sign-in"
        );
        return Ok(login_failed("The identity provider did not complete the sign-in."));
    };

    let identity = match state.oidc.finish(code, flow.get("nonce"), flow.get("pkce_verifier")).await
    {
        Ok(identity) => identity,
        Err(error) => {
            delete_flow().await?;
            tracing::warn!(error = format!("{error:#}"), "sign-in failed");
            return Ok(login_failed("The identity provider's response could not be verified."));
        }
    };

    let user_id: Uuid = sqlx::query_scalar(
        "INSERT INTO users (id, oidc_sub, username, created_at) VALUES (?, ?, ?, ?)
         ON CONFLICT (oidc_sub) DO UPDATE SET username = excluded.username
         RETURNING id",
    )
    .bind(Uuid::now_v7())
    .bind(&identity.sub)
    .bind(&identity.username)
    .bind(now())
    .fetch_one(&state.db)
    .await?;

    let client: String = flow.get("client");
    if client == "app" {
        let code = random_secret();
        sqlx::query(
            "UPDATE login_flows SET app_code_hash = ?, user_id = ?, expires_at = ? WHERE state = ?",
        )
        .bind(sha256(code.as_bytes()))
        .bind(user_id)
        .bind(now() + APP_CODE_LIFETIME)
        .bind(&flow_state)
        .execute(&state.db)
        .await?;
        return Ok(Redirect::to(&format!("habitd://auth?code={code}")).into_response());
    }

    delete_flow().await?;
    // Signing in again from a browser replaces the session it already had,
    // rather than leaving the old one behind in the list.
    if let Some(previous) = session_cookie(&headers) {
        sqlx::query("DELETE FROM tokens WHERE token_hash = ? AND user_id = ? AND kind = 'session'")
            .bind(sha256(previous.as_bytes()))
            .bind(user_id)
            .execute(&state.db)
            .await?;
    }
    let user_agent = headers.get(header::USER_AGENT).and_then(|v| v.to_str().ok()).unwrap_or("");
    let token = new_token();
    insert_token(
        &state.db,
        user_id,
        "session",
        &describe_browser(user_agent),
        &token,
        Some(now() + SESSION_LIFETIME),
    )
    .await?;
    let redirect_path: Option<String> = flow.get("redirect_path");
    let mut response = Redirect::to(redirect_path.as_deref().unwrap_or("/")).into_response();
    response.headers_mut().insert(header::SET_COOKIE, cookie(&state, &token, COOKIE_MAX_AGE));
    Ok(response)
}

#[derive(Deserialize)]
struct TokenRequest {
    code: String,
    code_verifier: String,
    device_name: Option<String>,
}

async fn token(
    State(state): State<AppState>,
    ApiJson(body): ApiJson<TokenRequest>,
) -> ApiResult<Response> {
    let invalid = || ApiError::bad_request("invalid or expired code");

    // The code is single-use: the row goes away whether or not the verifier matches.
    let flow = sqlx::query(
        "DELETE FROM login_flows WHERE app_code_hash = ?
         RETURNING app_challenge, user_id, expires_at",
    )
    .bind(sha256(body.code.as_bytes()))
    .fetch_optional(&state.db)
    .await?
    .ok_or_else(invalid)?;

    let challenge: Option<String> = flow.get("app_challenge");
    let user_id: Option<Uuid> = flow.get("user_id");
    let expires_at: i64 = flow.get("expires_at");
    let (Some(challenge), Some(user_id)) = (challenge, user_id) else {
        return Err(invalid());
    };
    if expires_at <= now() || pkce_s256(&body.code_verifier) != challenge {
        return Err(invalid());
    }

    let name = body
        .device_name
        .map(|name| name.trim().chars().take(100).collect::<String>())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "Android device".into());
    // A device signing in again (after a reinstall, say) replaces its old
    // credential, which nothing can use any more and would never expire.
    sqlx::query("DELETE FROM tokens WHERE user_id = ? AND kind = 'device' AND name = ?")
        .bind(user_id)
        .bind(&name)
        .execute(&state.db)
        .await?;
    let token = new_token();
    insert_token(&state.db, user_id, "device", &name, &token, None).await?;

    let user = sqlx::query("SELECT id, username, timezone, week_start FROM users WHERE id = ?")
        .bind(user_id)
        .fetch_one(&state.db)
        .await?;
    Ok(axum::Json(json!({
        "token": token,
        "user": {
            "id": user.get::<Uuid, _>("id"),
            "username": user.get::<String, _>("username"),
            "timezone": user.get::<String, _>("timezone"),
            "week_start": user.get::<i64, _>("week_start"),
        },
    }))
    .into_response())
}

async fn logout(State(state): State<AppState>, auth: AuthUser) -> ApiResult<Response> {
    sqlx::query("DELETE FROM tokens WHERE id = ?").bind(auth.token_id).execute(&state.db).await?;
    let mut headers = HeaderMap::new();
    headers.insert(header::SET_COOKIE, cookie(&state, "", 0));
    Ok((StatusCode::NO_CONTENT, headers).into_response())
}
