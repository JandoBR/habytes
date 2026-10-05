mod common;

use std::collections::HashMap;

use axum::{
    body::Body,
    http::{Request, StatusCode, header},
    response::Response,
};
use common::{MockIssuer, PUBLIC_URL, TestApp, error_code, read};
use habitd::util::{now, pkce_s256};
use serde_json::{Value, json};
use url::Url;

fn location(response: &Response) -> String {
    response.headers()[header::LOCATION].to_str().unwrap().to_string()
}

fn query(url: &str) -> HashMap<String, String> {
    Url::parse(url).unwrap().query_pairs().into_owned().collect()
}

async fn get(app: &TestApp, path: &str) -> Response {
    app.send(Request::get(path).body(Body::empty()).unwrap()).await
}

/// Starts a login and returns the provider's `state` and `nonce` parameters.
async fn begin(app: &TestApp, issuer: &MockIssuer, path: &str) -> (String, String) {
    let response = get(app, path).await;
    assert_eq!(response.status(), StatusCode::SEE_OTHER);
    let url = location(&response);
    assert!(url.starts_with(&format!("{}/authorize?", issuer.url)), "{url}");
    let params = query(&url);
    assert_eq!(params["response_type"], "code");
    assert_eq!(params["client_id"], common::CLIENT_ID);
    assert_eq!(params["redirect_uri"], format!("{PUBLIC_URL}/auth/callback"));
    assert_eq!(params["code_challenge_method"], "S256");
    assert_eq!(params["scope"], "openid profile email");
    (params["state"].clone(), params["nonce"].clone())
}

fn session_from(response: &Response) -> String {
    let cookie = response.headers()[header::SET_COOKIE].to_str().unwrap();
    assert!(
        cookie.contains("HttpOnly") && cookie.contains("Secure") && cookie.contains("SameSite=Lax")
    );
    let value = cookie.split(';').next().unwrap().strip_prefix("habitd_session=").unwrap();
    assert!(value.starts_with("hbt_"));
    value.to_string()
}

async fn me(app: &TestApp, session: &str) -> (StatusCode, Value) {
    let request = Request::get("/api/v1/me")
        .header(header::COOKIE, format!("habitd_session={session}"))
        .body(Body::empty())
        .unwrap();
    read(app.send(request).await).await
}

#[tokio::test]
async fn web_login_creates_a_user_and_a_session() {
    let issuer = MockIssuer::start().await;
    let app = TestApp::with_issuer(&issuer.url).await;

    let (state, nonce) = begin(&app, &issuer, "/auth/login?redirect=/history").await;
    issuer.will_return("sub-1", Some("jando"), Some("jando@example.com"), &nonce);
    let response = get(&app, &format!("/auth/callback?code=abc&state={state}")).await;
    assert_eq!(response.status(), StatusCode::SEE_OTHER);
    assert_eq!(location(&response), "/history");

    let (status, user) = me(&app, &session_from(&response)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(user["username"], "jando");
    assert_eq!(user["timezone"], "UTC");

    // The flow row is gone, so the callback cannot be replayed.
    let flows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM login_flows")
        .fetch_one(&app.state.db)
        .await
        .unwrap();
    assert_eq!(flows, 0);
    let replay = get(&app, &format!("/auth/callback?code=abc&state={state}")).await;
    assert_eq!(replay.status(), StatusCode::BAD_REQUEST);
    assert!(replay.headers().get(header::SET_COOKIE).is_none());
}

#[tokio::test]
async fn logging_in_again_reuses_the_user_and_refreshes_the_username() {
    let issuer = MockIssuer::start().await;
    let app = TestApp::with_issuer(&issuer.url).await;

    let mut ids = Vec::new();
    // preferred_username, then email, then sub.
    let cases = [
        (Some("jando"), Some("j@example.com"), "jando"),
        (None, Some("j@example.com"), "j@example.com"),
        (None, None, "sub-1"),
    ];
    for (username, email, expected) in cases {
        let (state, nonce) = begin(&app, &issuer, "/auth/login").await;
        issuer.will_return("sub-1", username, email, &nonce);
        let response = get(&app, &format!("/auth/callback?code=abc&state={state}")).await;
        assert_eq!(location(&response), "/");
        let (_, user) = me(&app, &session_from(&response)).await;
        assert_eq!(user["username"], expected);
        ids.push(user["id"].clone());
    }
    assert!(ids.iter().all(|id| *id == ids[0]));
}

#[tokio::test]
async fn id_tokens_that_do_not_verify_are_rejected() {
    let issuer = MockIssuer::start().await;
    let app = TestApp::with_issuer(&issuer.url).await;

    // Wrong nonce.
    let (state, _) = begin(&app, &issuer, "/auth/login").await;
    issuer.will_return("sub-1", Some("jando"), None, "some-other-nonce");
    let response = get(&app, &format!("/auth/callback?code=abc&state={state}")).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    assert!(response.headers().get(header::SET_COOKIE).is_none());

    // Wrong audience.
    let (state, nonce) = begin(&app, &issuer, "/auth/login").await;
    issuer.will_return("sub-1", Some("jando"), None, &nonce);
    issuer.identity.lock().unwrap().as_mut().unwrap().audience = "someone-else".into();
    let response = get(&app, &format!("/auth/callback?code=abc&state={state}")).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let users: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM users").fetch_one(&app.state.db).await.unwrap();
    assert_eq!(users, 0);
}

#[tokio::test]
async fn callbacks_need_a_known_unexpired_state() {
    let issuer = MockIssuer::start().await;
    let app = TestApp::with_issuer(&issuer.url).await;

    let response = get(&app, "/auth/callback?code=abc&state=made-up").await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let response = get(&app, "/auth/callback?code=abc").await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let (state, nonce) = begin(&app, &issuer, "/auth/login").await;
    issuer.will_return("sub-1", Some("jando"), None, &nonce);
    sqlx::query("UPDATE login_flows SET expires_at = ?")
        .bind(now() - 1)
        .execute(&app.state.db)
        .await
        .unwrap();
    let response = get(&app, &format!("/auth/callback?code=abc&state={state}")).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    // The provider reporting an error ends the flow.
    let (state, _) = begin(&app, &issuer, "/auth/login").await;
    let response = get(&app, &format!("/auth/callback?error=access_denied&state={state}")).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn login_redirect_must_be_a_local_path() {
    let issuer = MockIssuer::start().await;
    let app = TestApp::with_issuer(&issuer.url).await;
    for bad in ["https://evil.test", "//evil.test", "/%5Cevil.test", "history"] {
        let response = get(&app, &format!("/auth/login?redirect={bad}")).await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "{bad}");
    }
    for bad in [
        "/auth/login?client=app",
        "/auth/login?client=app&code_challenge=short",
        "/auth/login?client=tv",
    ] {
        assert_eq!(get(&app, bad).await.status(), StatusCode::BAD_REQUEST, "{bad}");
    }
}

async fn exchange(app: &TestApp, body: Value) -> (StatusCode, Value) {
    let request = Request::post("/auth/token")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    read(app.send(request).await).await
}

/// Runs the app login up to the `habitd://` redirect and returns the one-time code.
async fn app_code(app: &TestApp, issuer: &MockIssuer, verifier: &str) -> String {
    let path = format!("/auth/login?client=app&code_challenge={}", pkce_s256(verifier));
    let (state, nonce) = begin(app, issuer, &path).await;
    issuer.will_return("sub-1", Some("jando"), None, &nonce);
    let response = get(app, &format!("/auth/callback?code=abc&state={state}")).await;
    assert_eq!(response.status(), StatusCode::SEE_OTHER);
    assert!(response.headers().get(header::SET_COOKIE).is_none());
    let url = location(&response);
    assert!(url.starts_with("habitd://auth?code="), "{url}");
    query(&url)["code"].clone()
}

#[tokio::test]
async fn app_login_hands_over_a_device_token() {
    let issuer = MockIssuer::start().await;
    let app = TestApp::with_issuer(&issuer.url).await;
    let verifier = "a-verifier-that-is-long-enough-to-be-plausible-0123";

    let code = app_code(&app, &issuer, verifier).await;
    let body = json!({ "code": code, "code_verifier": verifier, "device_name": "Pixel" });
    let (status, response) = exchange(&app, body.clone()).await;
    assert_eq!(status, StatusCode::OK, "{response}");
    assert_eq!(response["user"]["username"], "jando");
    let token = response["token"].as_str().unwrap();

    let (status, tokens) = app.get(token, "/api/v1/tokens").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(tokens[0]["kind"], "device");
    assert_eq!(tokens[0]["name"], "Pixel");
    assert_eq!(tokens[0]["expires_at"], Value::Null);

    // The code is single-use.
    let (status, error) = exchange(&app, body).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(error_code(&error), "bad_request");
}

#[tokio::test]
async fn app_codes_need_the_right_verifier_and_expire() {
    let issuer = MockIssuer::start().await;
    let app = TestApp::with_issuer(&issuer.url).await;
    let verifier = "a-verifier-that-is-long-enough-to-be-plausible-0123";

    // A wrong verifier fails and burns the code.
    let code = app_code(&app, &issuer, verifier).await;
    let (status, _) = exchange(&app, json!({ "code": code, "code_verifier": "wrong" })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = exchange(&app, json!({ "code": code, "code_verifier": verifier })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // The code lives for 60 seconds.
    let code = app_code(&app, &issuer, verifier).await;
    let expires: i64 = sqlx::query_scalar("SELECT expires_at FROM login_flows")
        .fetch_one(&app.state.db)
        .await
        .unwrap();
    assert!((now() + 55..=now() + 60).contains(&expires));
    sqlx::query("UPDATE login_flows SET expires_at = ?")
        .bind(now() - 1)
        .execute(&app.state.db)
        .await
        .unwrap();
    let (status, _) = exchange(&app, json!({ "code": code, "code_verifier": verifier })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let tokens: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM tokens").fetch_one(&app.state.db).await.unwrap();
    assert_eq!(tokens, 0);
}

#[tokio::test]
async fn auth_endpoints_are_rate_limited_per_ip() {
    let app = TestApp::new().await;
    for _ in 0..20 {
        let (status, _) = exchange(&app, json!({ "code": "x", "code_verifier": "y" })).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
    let (status, error) = exchange(&app, json!({ "code": "x", "code_verifier": "y" })).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(error_code(&error), "rate_limited");
}

/// A full web login, optionally from a browser that already has a session.
async fn web_login(
    app: &TestApp,
    issuer: &MockIssuer,
    user_agent: &str,
    previous: Option<&str>,
) -> String {
    let (state, nonce) = begin(app, issuer, "/auth/login").await;
    issuer.will_return("sub-1", Some("jando"), None, &nonce);
    let mut request = Request::get(format!("/auth/callback?code=abc&state={state}"))
        .header(header::USER_AGENT, user_agent);
    if let Some(session) = previous {
        request = request.header(header::COOKIE, format!("habitd_session={session}"));
    }
    let response = app.send(request.body(Body::empty()).unwrap()).await;
    assert_eq!(response.status(), StatusCode::SEE_OTHER);
    session_from(&response)
}

async fn token_names(app: &TestApp, session: &str) -> Vec<String> {
    let request = Request::get("/api/v1/tokens")
        .header(header::COOKIE, format!("habitd_session={session}"))
        .body(Body::empty())
        .unwrap();
    let (status, tokens) = read(app.send(request).await).await;
    assert_eq!(status, StatusCode::OK);
    let mut names: Vec<String> =
        tokens.as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap().into()).collect();
    names.sort();
    names
}

#[tokio::test]
async fn signing_in_again_replaces_the_old_credential() {
    const FIREFOX: &str = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0";
    const CHROME_ANDROID: &str = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like \
                                  Gecko) Chrome/140.0 Mobile Safari/537.36";
    let issuer = MockIssuer::start().await;
    let app = TestApp::with_issuer(&issuer.url).await;

    // Sessions are named after the browser that made them.
    let first = web_login(&app, &issuer, FIREFOX, None).await;
    assert_eq!(token_names(&app, &first).await, ["Firefox on Linux"]);

    // The same browser signing in again replaces its session...
    let second = web_login(&app, &issuer, FIREFOX, Some(&first)).await;
    assert_eq!(token_names(&app, &second).await, ["Firefox on Linux"]);
    assert_eq!(me(&app, &first).await.0, StatusCode::UNAUTHORIZED);
    // ...while another browser gets one of its own.
    let phone = web_login(&app, &issuer, CHROME_ANDROID, None).await;
    assert_eq!(token_names(&app, &phone).await, ["Chrome on Android", "Firefox on Linux"]);
    assert_eq!(me(&app, &second).await.0, StatusCode::OK);

    // A device signing in again under the same name replaces its token too.
    let verifier = "a-verifier-that-is-long-enough-to-be-plausible-0123";
    let mut device_tokens = Vec::new();
    for name in ["POCO X3 GT", "POCO X3 GT", "Tablet"] {
        let code = app_code(&app, &issuer, verifier).await;
        let body = json!({ "code": code, "code_verifier": verifier, "device_name": name });
        let (status, response) = exchange(&app, body).await;
        assert_eq!(status, StatusCode::OK, "{response}");
        device_tokens.push(response["token"].as_str().unwrap().to_string());
    }
    assert_eq!(
        token_names(&app, &second).await,
        ["Chrome on Android", "Firefox on Linux", "POCO X3 GT", "Tablet"]
    );
    assert_eq!(app.get(&device_tokens[0], "/api/v1/me").await.0, StatusCode::UNAUTHORIZED);
    assert_eq!(app.get(&device_tokens[1], "/api/v1/me").await.0, StatusCode::OK);
}
