use std::{str::FromStr, time::Duration};

use sqlx::{
    SqlitePool,
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions},
};

use crate::util::now;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

/// Opens (creating if needed) the database file and runs migrations.
pub async fn connect(path: &str) -> anyhow::Result<SqlitePool> {
    let options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .foreign_keys(true)
        .busy_timeout(Duration::from_millis(5000));
    let pool = SqlitePoolOptions::new().connect_with(options).await?;
    MIGRATOR.run(&pool).await?;
    Ok(pool)
}

/// A private in-memory database, for tests.
pub async fn connect_memory() -> anyhow::Result<SqlitePool> {
    let options = SqliteConnectOptions::from_str("sqlite::memory:")?.foreign_keys(true);
    // One connection that is never recycled: the database lives and dies with it.
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .idle_timeout(None)
        .max_lifetime(None)
        .connect_with(options)
        .await?;
    MIGRATOR.run(&pool).await?;
    Ok(pool)
}

const APPLIED_OPS_RETENTION: i64 = 30 * 24 * 3600;

/// Deletes old `applied_ops`, expired tokens and expired login flows.
pub async fn cleanup(pool: &SqlitePool) -> sqlx::Result<()> {
    let now = now();
    sqlx::query("DELETE FROM applied_ops WHERE created_at < ?")
        .bind(now - APPLIED_OPS_RETENTION)
        .execute(pool)
        .await?;
    sqlx::query("DELETE FROM tokens WHERE expires_at IS NOT NULL AND expires_at <= ?")
        .bind(now)
        .execute(pool)
        .await?;
    sqlx::query("DELETE FROM login_flows WHERE expires_at <= ?").bind(now).execute(pool).await?;
    Ok(())
}
