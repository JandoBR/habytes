use std::net::SocketAddr;

use figment::{
    Figment,
    providers::{Env, Format, Serialized, Toml},
};
use serde::{Deserialize, Serialize};
use url::Url;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub database_path: String,
    pub bind_address: SocketAddr,
    pub public_url: String,
    /// Take the client address from `X-Forwarded-For` (set this when running
    /// behind a reverse proxy, so rate limits apply per client and not per proxy).
    #[serde(default)]
    pub trust_forwarded_for: bool,
    pub oidc: OidcConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OidcConfig {
    pub issuer: String,
    pub client_id: String,
    #[serde(default)]
    pub client_secret: Option<String>,
    #[serde(default = "default_scopes")]
    pub scopes: Vec<String>,
}

fn default_scopes() -> Vec<String> {
    ["openid", "profile", "email"].map(String::from).to_vec()
}

impl Config {
    /// Reads `path` (if it exists) and applies `HABITD_*` environment overrides.
    /// Nested keys use a double underscore: `HABITD_OIDC__CLIENT_SECRET`.
    pub fn load(path: &str) -> anyhow::Result<Self> {
        let defaults = serde_json::json!({
            "database_path": "habits.db",
            "bind_address": "0.0.0.0:8080",
        });
        let mut config: Config = Figment::from(Serialized::defaults(defaults))
            .merge(Toml::file(path))
            .merge(Env::prefixed("HABITD_").split("__"))
            .extract()?;
        config.normalize()?;
        Ok(config)
    }

    pub fn normalize(&mut self) -> anyhow::Result<()> {
        let url = Url::parse(&self.public_url)
            .map_err(|e| anyhow::anyhow!("public_url is not a valid URL: {e}"))?;
        anyhow::ensure!(
            matches!(url.scheme(), "http" | "https") && url.host_str().is_some(),
            "public_url must be an http(s) URL"
        );
        self.public_url = self.public_url.trim_end_matches('/').to_string();
        Ok(())
    }

    /// `scheme://host[:port]`, the value browsers send in the `Origin` header.
    pub fn origin(&self) -> String {
        Url::parse(&self.public_url).map(|u| u.origin().ascii_serialization()).unwrap_or_default()
    }

    pub fn is_https(&self) -> bool {
        self.public_url.starts_with("https://")
    }
}
