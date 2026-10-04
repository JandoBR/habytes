use std::{ops::Deref, sync::Arc};

use sqlx::SqlitePool;

use crate::{config::Config, oidc::Oidc, ratelimit::RateLimiter};

#[derive(Clone)]
pub struct AppState(Arc<Inner>);

pub struct Inner {
    pub db: SqlitePool,
    pub config: Config,
    pub oidc: Oidc,
    pub auth_limiter: RateLimiter,
    pub hook_limiter: RateLimiter,
}

impl AppState {
    pub fn new(db: SqlitePool, config: Config) -> anyhow::Result<Self> {
        let oidc = Oidc::new(&config)?;
        Ok(Self(Arc::new(Inner {
            db,
            config,
            oidc,
            auth_limiter: RateLimiter::per_minute(20),
            hook_limiter: RateLimiter::per_minute(60),
        })))
    }
}

impl Deref for AppState {
    type Target = Inner;

    fn deref(&self) -> &Inner {
        &self.0
    }
}
