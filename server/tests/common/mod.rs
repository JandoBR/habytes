#![allow(dead_code)]

use std::sync::{Arc, Mutex};

use axum::{
    Json, Router,
    body::Body,
    extract::State,
    http::{Method, Request, StatusCode, header},
    response::Response,
    routing::{get, post},
};
use habitd::{
    auth::{insert_token, new_token},
    config::{Config, OidcConfig},
    db,
    state::AppState,
    util::now,
};
use http_body_util::BodyExt;
use openidconnect::{
    Audience, EmptyAdditionalClaims, EndUserEmail, EndUserUsername, IssuerUrl, JsonWebKeyId, Nonce,
    PrivateSigningKey, StandardClaims, SubjectIdentifier,
    core::{
        CoreIdToken, CoreIdTokenClaims, CoreJsonWebKeySet, CoreJwsSigningAlgorithm,
        CoreRsaPrivateSigningKey,
    },
};
use serde_json::{Value, json};
use tower::ServiceExt;
use uuid::Uuid;

pub const PUBLIC_URL: &str = "https://habits.test";
pub const CLIENT_ID: &str = "habitd-test";
const TEST_KEY: &str = include_str!("TEST-ONLY-key.pem");

/// What the mock provider will put in the next ID token.
#[derive(Clone)]
pub struct MockIdentity {
    pub sub: String,
    pub preferred_username: Option<String>,
    pub email: Option<String>,
    pub nonce: String,
    pub audience: String,
}

pub struct MockIssuer {
    pub url: String,
    pub identity: Mutex<Option<MockIdentity>>,
}

impl MockIssuer {
    /// Serves discovery, JWKS and the token endpoint on a local port.
    pub async fn start() -> Arc<Self> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let issuer = Arc::new(Self { url, identity: Mutex::new(None) });
        let router = Router::new()
            .route("/.well-known/openid-configuration", get(discovery))
            .route("/jwks", get(jwks))
            .route("/token", post(token))
            .with_state(issuer.clone());
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        issuer
    }

    pub fn will_return(&self, sub: &str, username: Option<&str>, email: Option<&str>, nonce: &str) {
        *self.identity.lock().unwrap() = Some(MockIdentity {
            sub: sub.into(),
            preferred_username: username.map(Into::into),
            email: email.map(Into::into),
            nonce: nonce.into(),
            audience: CLIENT_ID.into(),
        });
    }
}

fn signing_key() -> CoreRsaPrivateSigningKey {
    CoreRsaPrivateSigningKey::from_pem(TEST_KEY, Some(JsonWebKeyId::new("test".into()))).unwrap()
}

async fn discovery(State(issuer): State<Arc<MockIssuer>>) -> Json<Value> {
    let url = &issuer.url;
    Json(json!({
        "issuer": url,
        "authorization_endpoint": format!("{url}/authorize"),
        "token_endpoint": format!("{url}/token"),
        "jwks_uri": format!("{url}/jwks"),
        "response_types_supported": ["code"],
        "subject_types_supported": ["public"],
        "id_token_signing_alg_values_supported": ["RS256"],
    }))
}

async fn jwks() -> Json<Value> {
    let keys = CoreJsonWebKeySet::new(vec![signing_key().as_verification_key()]);
    Json(serde_json::to_value(keys).unwrap())
}

async fn token(State(issuer): State<Arc<MockIssuer>>) -> Result<Json<Value>, StatusCode> {
    let identity = issuer.identity.lock().unwrap().clone().ok_or(StatusCode::BAD_REQUEST)?;
    let standard = StandardClaims::new(SubjectIdentifier::new(identity.sub))
        .set_preferred_username(identity.preferred_username.map(EndUserUsername::new))
        .set_email(identity.email.map(EndUserEmail::new));
    let claims = CoreIdTokenClaims::new(
        IssuerUrl::new(issuer.url.clone()).unwrap(),
        vec![Audience::new(identity.audience)],
        chrono::Utc::now() + chrono::Duration::minutes(5),
        chrono::Utc::now(),
        standard,
        EmptyAdditionalClaims {},
    )
    .set_nonce(Some(Nonce::new(identity.nonce)));
    let id_token = CoreIdToken::new(
        claims,
        &signing_key(),
        CoreJwsSigningAlgorithm::RsaSsaPkcs1V15Sha256,
        None,
        None,
    )
    .unwrap();
    Ok(Json(json!({
        "access_token": "mock-access-token",
        "token_type": "Bearer",
        "id_token": id_token.to_string(),
    })))
}

pub struct TestApp {
    pub router: Router,
    pub state: AppState,
}

impl TestApp {
    /// An app whose OIDC issuer is never contacted.
    pub async fn new() -> Self {
        Self::with_issuer("http://127.0.0.1:9").await
    }

    pub async fn with_issuer(issuer: &str) -> Self {
        let config = Config {
            database_path: ":memory:".into(),
            bind_address: "127.0.0.1:0".parse().unwrap(),
            public_url: PUBLIC_URL.into(),
            trust_forwarded_for: false,
            oidc: OidcConfig {
                issuer: issuer.into(),
                client_id: CLIENT_ID.into(),
                client_secret: Some("secret".into()),
                scopes: vec!["openid".into(), "profile".into(), "email".into()],
            },
        };
        let state = AppState::new(db::connect_memory().await.unwrap(), config).unwrap();
        Self { router: habitd::router(state.clone()), state }
    }

    /// Creates a user directly in the database and returns an API token for them.
    pub async fn user(&self, name: &str) -> String {
        let id = self.user_id(name).await;
        let token = new_token();
        insert_token(&self.state.db, id, "api", "test", &token, None).await.unwrap();
        token
    }

    /// The ID of the user called `name`, created if needed.
    pub async fn user_id(&self, name: &str) -> Uuid {
        sqlx::query_scalar(
            "INSERT INTO users (id, oidc_sub, username, created_at) VALUES (?, ?, ?, ?)
             ON CONFLICT (oidc_sub) DO UPDATE SET username = excluded.username RETURNING id",
        )
        .bind(Uuid::now_v7())
        .bind(format!("sub-{name}"))
        .bind(name)
        .bind(now())
        .fetch_one(&self.state.db)
        .await
        .unwrap()
    }

    /// Creates a web session for `name` and returns the cookie value.
    pub async fn session(&self, name: &str) -> String {
        let id = self.user_id(name).await;
        let token = new_token();
        insert_token(&self.state.db, id, "session", "Web session", &token, Some(now() + 3600))
            .await
            .unwrap();
        token
    }

    pub async fn send(&self, request: Request<Body>) -> Response {
        self.router.clone().oneshot(request).await.unwrap()
    }

    /// A JSON request with a bearer token (pass `Value::Null` for no body).
    pub async fn api(
        &self,
        token: &str,
        method: &str,
        path: &str,
        body: Value,
    ) -> (StatusCode, Value) {
        let mut request = Request::builder()
            .method(Method::from_bytes(method.as_bytes()).unwrap())
            .uri(path)
            .header(header::AUTHORIZATION, format!("Bearer {token}"));
        let body = if body.is_null() {
            Body::empty()
        } else {
            request = request.header(header::CONTENT_TYPE, "application/json");
            Body::from(body.to_string())
        };
        read(self.send(request.body(body).unwrap()).await).await
    }

    pub async fn get(&self, token: &str, path: &str) -> (StatusCode, Value) {
        self.api(token, "GET", path, Value::Null).await
    }

    /// Creates a habit and returns its ID.
    pub async fn habit(&self, token: &str, body: Value) -> String {
        let (status, habit) = self.api(token, "POST", "/api/v1/habits", body).await;
        assert_eq!(status, StatusCode::CREATED, "{habit}");
        habit["id"].as_str().unwrap().to_string()
    }

    pub async fn set(&self, token: &str, habit: &str, date: &str, value: i64) -> Value {
        let path = format!("/api/v1/habits/{habit}/entries/{date}");
        let (status, body) = self.api(token, "PUT", &path, json!({ "value": value })).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body
    }

    pub async fn increment(&self, token: &str, habit: &str, date: &str, delta: i64) -> Value {
        let path = format!("/api/v1/habits/{habit}/entries/{date}/increment");
        let body = json!({ "op_id": Uuid::now_v7(), "delta": delta });
        let (status, body) = self.api(token, "POST", &path, body).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body
    }
}

/// Splits a response into its status and JSON body (`Null` if there is none).
pub async fn read(response: Response) -> (StatusCode, Value) {
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let body = if bytes.is_empty() { Value::Null } else { serde_json::from_slice(&bytes).unwrap() };
    (status, body)
}

pub fn error_code(body: &Value) -> &str {
    body["error"]["code"].as_str().unwrap_or("")
}
