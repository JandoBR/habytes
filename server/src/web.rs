//! The embedded web app, served for every path the API does not claim.

use axum::{
    extract::{Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Redirect, Response},
};

use crate::{
    error::ApiError,
    extract::session_cookie,
    state::AppState,
    util::{now, sha256},
};

#[cfg(feature = "embed-web")]
#[derive(rust_embed::RustEmbed)]
#[folder = "../app/build/web"]
struct Assets;

/// An embedded file and its content hash.
#[cfg(feature = "embed-web")]
fn asset(path: &str) -> Option<(std::borrow::Cow<'static, [u8]>, String)> {
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    let file = Assets::get(path)?;
    let etag = format!("\"{}\"", URL_SAFE_NO_PAD.encode(file.metadata.sha256_hash()));
    Some((file.data, etag))
}

#[cfg(not(feature = "embed-web"))]
fn asset(_path: &str) -> Option<(std::borrow::Cow<'static, [u8]>, String)> {
    None
}

fn serve(path: &str, request: &HeaderMap) -> Option<Response> {
    let (data, etag) = asset(path)?;
    let headers = [
        (header::ETAG, HeaderValue::from_str(&etag).ok()?),
        // Files are not fingerprinted, so always revalidate; the ETag keeps that cheap.
        (header::CACHE_CONTROL, HeaderValue::from_static("no-cache")),
    ];
    if request.get(header::IF_NONE_MATCH).is_some_and(|v| v.as_bytes() == etag.as_bytes()) {
        return Some((StatusCode::NOT_MODIFIED, headers).into_response());
    }
    let mime = mime_guess::from_path(path).first_or_octet_stream();
    let content_type = HeaderValue::from_str(mime.as_ref()).ok()?;
    Some((headers, [(header::CONTENT_TYPE, content_type)], data.into_owned()).into_response())
}

async fn has_session(state: &AppState, headers: &HeaderMap) -> Result<bool, ApiError> {
    let Some(token) = session_cookie(headers) else {
        return Ok(false);
    };
    let found: Option<i64> = sqlx::query_scalar(
        "SELECT 1 FROM tokens WHERE token_hash = ? AND kind = 'session'
         AND (expires_at IS NULL OR expires_at > ?)",
    )
    .bind(sha256(token.as_bytes()))
    .bind(now())
    .fetch_optional(&state.db)
    .await?;
    Ok(found.is_some())
}

pub async fn fallback(State(state): State<AppState>, request: Request) -> Response {
    // The body is never read, and holding it across an await would make the future `!Send`.
    let (request, _) = request.into_parts();
    let path = request.uri.path();
    if ["/api/", "/auth/", "/hook/"].iter().any(|prefix| path.starts_with(prefix)) {
        return ApiError::NotFound.into_response();
    }
    if !matches!(request.method, axum::http::Method::GET | axum::http::Method::HEAD) {
        return StatusCode::METHOD_NOT_ALLOWED.into_response();
    }
    if let Some(response) = serve(path.trim_start_matches('/'), &request.headers) {
        return response;
    }

    // Anything else is a page of the app: it needs a session, then index.html
    // lets the app's own router take over.
    match has_session(&state, &request.headers).await {
        Ok(true) => {}
        Ok(false) => {
            let target = request.uri.path_and_query().map_or("/", |p| p.as_str());
            let query = url::form_urlencoded::Serializer::new(String::new())
                .append_pair("redirect", target)
                .finish();
            return Redirect::to(&format!("/auth/login?{query}")).into_response();
        }
        Err(error) => return error.into_response(),
    }
    serve("index.html", &request.headers)
        .unwrap_or_else(|| (StatusCode::NOT_FOUND, "the web app is not built in").into_response())
}
