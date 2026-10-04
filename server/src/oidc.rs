//! The relying-party side of the OIDC authorization code flow.

use anyhow::{Context, anyhow};
use openidconnect::{
    AuthorizationCode, ClientId, ClientSecret, CsrfToken, EndpointMaybeSet, EndpointNotSet,
    EndpointSet, IssuerUrl, Nonce, PkceCodeChallenge, PkceCodeVerifier, RedirectUrl, Scope,
    TokenResponse,
    core::{CoreAuthenticationFlow, CoreClient, CoreProviderMetadata},
    reqwest,
};
use tokio::sync::RwLock;

use crate::config::{Config, OidcConfig};

type Client = CoreClient<
    EndpointSet,
    EndpointNotSet,
    EndpointNotSet,
    EndpointNotSet,
    EndpointMaybeSet,
    EndpointMaybeSet,
>;

pub struct Oidc {
    config: OidcConfig,
    redirect_url: RedirectUrl,
    http: reqwest::Client,
    /// Discovery document and keys, fetched on first use.
    metadata: RwLock<Option<CoreProviderMetadata>>,
}

/// What to remember between the redirect to the provider and its callback.
pub struct AuthStart {
    pub url: String,
    pub state: String,
    pub nonce: String,
    pub pkce_verifier: String,
}

pub struct Identity {
    pub sub: String,
    pub username: String,
}

impl Oidc {
    pub fn new(config: &Config) -> anyhow::Result<Self> {
        let http = reqwest::ClientBuilder::new()
            // Following redirects would open the client up to SSRF.
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(15))
            .build()?;
        Ok(Self {
            config: config.oidc.clone(),
            redirect_url: RedirectUrl::new(format!("{}/auth/callback", config.public_url))?,
            http,
            metadata: RwLock::new(None),
        })
    }

    async fn client(&self, refresh: bool) -> anyhow::Result<Client> {
        let cached = if refresh { None } else { self.metadata.read().await.clone() };
        let metadata = match cached {
            Some(metadata) => metadata,
            None => {
                let issuer = IssuerUrl::new(self.config.issuer.clone())?;
                let metadata = CoreProviderMetadata::discover_async(issuer, &self.http)
                    .await
                    .map_err(|e| anyhow!("OIDC discovery failed: {e}"))?;
                *self.metadata.write().await = Some(metadata.clone());
                metadata
            }
        };
        Ok(CoreClient::from_provider_metadata(
            metadata,
            ClientId::new(self.config.client_id.clone()),
            self.config.client_secret.clone().map(ClientSecret::new),
        )
        .set_redirect_uri(self.redirect_url.clone()))
    }

    pub async fn begin(&self) -> anyhow::Result<AuthStart> {
        let client = self.client(false).await?;
        let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
        let mut request = client
            .authorize_url(
                CoreAuthenticationFlow::AuthorizationCode,
                CsrfToken::new_random,
                Nonce::new_random,
            )
            .set_pkce_challenge(challenge);
        // `openid` is always requested by the library.
        for scope in self.config.scopes.iter().filter(|s| *s != "openid") {
            request = request.add_scope(Scope::new(scope.clone()));
        }
        let (url, state, nonce) = request.url();
        Ok(AuthStart {
            url: url.to_string(),
            state: state.secret().clone(),
            nonce: nonce.secret().clone(),
            pkce_verifier: verifier.secret().clone(),
        })
    }

    pub async fn finish(
        &self,
        code: String,
        nonce: String,
        pkce_verifier: String,
    ) -> anyhow::Result<Identity> {
        let client = self.client(false).await?;
        let response = client
            .exchange_code(AuthorizationCode::new(code))?
            .set_pkce_verifier(PkceCodeVerifier::new(pkce_verifier))
            .request_async(&self.http)
            .await
            .map_err(|e| anyhow!("code exchange failed: {e}"))?;
        let id_token = response.id_token().context("provider returned no ID token")?;
        let nonce = Nonce::new(nonce);

        let claims = match id_token.claims(&client.id_token_verifier(), &nonce) {
            Ok(claims) => claims.clone(),
            Err(_) => {
                // The provider may have rotated its keys since discovery.
                let client = self.client(true).await?;
                id_token
                    .claims(&client.id_token_verifier(), &nonce)
                    .map_err(|e| anyhow!("ID token rejected: {e}"))?
                    .clone()
            }
        };

        let sub = claims.subject().to_string();
        let username = claims
            .preferred_username()
            .map(|name| name.to_string())
            .or_else(|| claims.email().map(|email| email.to_string()))
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| sub.clone());
        Ok(Identity { sub, username })
    }
}
