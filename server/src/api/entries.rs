use std::collections::HashMap;

use axum::{
    Json,
    extract::{Path, Query, State},
};
use chrono::{Days, NaiveDate};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::{Row, SqliteConnection};
use uuid::Uuid;

use crate::{
    api::habits::{self, Habit},
    error::{ApiError, ApiResult},
    extract::{ApiJson, AuthUser},
    schedule::{
        is_due, mask_to_weekdays, max_value, parse_date, parse_writable_date, today_in,
        week_start_date,
    },
    state::AppState,
    util::now,
};

/// The longest range `GET /entries` will return, in days, inclusive.
const MAX_RANGE_DAYS: i64 = 366;

/// One habit's status on one day, as returned by every write.
pub async fn status(
    conn: &mut SqliteConnection,
    habit: &Habit,
    week_start: i64,
    date: NaiveDate,
) -> sqlx::Result<Value> {
    let value: i64 =
        sqlx::query_scalar("SELECT value FROM entries WHERE habit_id = ? AND date = ?")
            .bind(habit.id)
            .bind(date.to_string())
            .fetch_optional(&mut *conn)
            .await?
            .unwrap_or(0);
    let period_value = if habit.schedule == "weekly" {
        let start = week_start_date(date, week_start);
        sqlx::query_scalar(
            "SELECT COALESCE(SUM(value), 0) FROM entries
             WHERE habit_id = ? AND date BETWEEN ? AND ?",
        )
        .bind(habit.id)
        .bind(start.to_string())
        .bind((start + Days::new(6)).to_string())
        .fetch_one(&mut *conn)
        .await?
    } else {
        value
    };
    Ok(json!({
        "habit_id": habit.id,
        "date": date.to_string(),
        "value": value,
        "period_value": period_value,
        "done": period_value >= habit.goal,
    }))
}

/// Adds `delta` to one day's value, clamped, unless `op_id` was already applied.
pub async fn apply_increment(
    conn: &mut SqliteConnection,
    habit: &Habit,
    date: NaiveDate,
    op_id: Uuid,
    delta: i64,
) -> sqlx::Result<()> {
    let now = now();
    let first_time = sqlx::query(
        "INSERT INTO applied_ops (op_id, habit_id, created_at) VALUES (?, ?, ?)
         ON CONFLICT (op_id) DO NOTHING",
    )
    .bind(op_id)
    .bind(habit.id)
    .bind(now)
    .execute(&mut *conn)
    .await?
    .rows_affected()
        == 1;
    if first_time {
        let max = max_value(&habit.kind);
        sqlx::query(
            "INSERT INTO entries (habit_id, date, value, updated_at)
             VALUES (?1, ?2, MAX(0, MIN(?4, ?3)), ?5)
             ON CONFLICT (habit_id, date) DO UPDATE
             SET value = MAX(0, MIN(?4, value + ?3)), updated_at = ?5",
        )
        .bind(habit.id)
        .bind(date.to_string())
        .bind(delta)
        .bind(max)
        .bind(now)
        .execute(&mut *conn)
        .await?;
    }
    Ok(())
}

/// Sets one day's value, clamped to what the habit's kind allows.
pub async fn apply_set(
    conn: &mut SqliteConnection,
    habit: &Habit,
    date: NaiveDate,
    value: i64,
) -> sqlx::Result<()> {
    sqlx::query(
        "INSERT INTO entries (habit_id, date, value, updated_at) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT (habit_id, date) DO UPDATE SET value = ?3, updated_at = ?4",
    )
    .bind(habit.id)
    .bind(date.to_string())
    .bind(value.clamp(0, max_value(&habit.kind)))
    .bind(now())
    .execute(&mut *conn)
    .await?;
    Ok(())
}

pub fn validate_delta(delta: i64) -> ApiResult<()> {
    if delta == 0 || !(-1000..=1000).contains(&delta) {
        return Err(ApiError::validation("delta must be a non-zero integer from -1000 to 1000"));
    }
    Ok(())
}

#[derive(Deserialize)]
pub struct Increment {
    op_id: Uuid,
    #[serde(default = "one")]
    delta: i64,
}

fn one() -> i64 {
    1
}

pub async fn increment(
    State(state): State<AppState>,
    auth: AuthUser,
    Path((id, date)): Path<(String, String)>,
    ApiJson(body): ApiJson<Increment>,
) -> ApiResult<Json<Value>> {
    let habit = habits::find(&state.db, auth.user.id, &id).await?;
    let date = parse_writable_date(&date)?;
    validate_delta(body.delta)?;

    let mut tx = state.db.begin().await?;
    apply_increment(&mut tx, &habit, date, body.op_id, body.delta).await?;
    let status = status(&mut tx, &habit, auth.user.week_start, date).await?;
    tx.commit().await?;
    Ok(Json(status))
}

#[derive(Deserialize)]
pub struct SetValue {
    value: i64,
}

pub async fn set(
    State(state): State<AppState>,
    auth: AuthUser,
    Path((id, date)): Path<(String, String)>,
    ApiJson(body): ApiJson<SetValue>,
) -> ApiResult<Json<Value>> {
    let habit = habits::find(&state.db, auth.user.id, &id).await?;
    let date = parse_writable_date(&date)?;
    if body.value < 0 {
        return Err(ApiError::validation("value must not be negative"));
    }

    let mut tx = state.db.begin().await?;
    apply_set(&mut tx, &habit, date, body.value).await?;
    let status = status(&mut tx, &habit, auth.user.week_start, date).await?;
    tx.commit().await?;
    Ok(Json(status))
}

#[derive(Deserialize)]
pub struct TodayQuery {
    date: Option<String>,
}

pub async fn today(
    State(state): State<AppState>,
    auth: AuthUser,
    Query(query): Query<TodayQuery>,
) -> ApiResult<Json<Value>> {
    let date = match &query.date {
        Some(raw) => parse_date(raw)?,
        None => today_in(&auth.user.timezone),
    };
    let week_start = week_start_date(date, auth.user.week_start);

    let habits: Vec<Habit> = sqlx::query_as(
        "SELECT * FROM habits WHERE user_id = ? AND archived = 0 ORDER BY position, created_at, id",
    )
    .bind(auth.user.id)
    .fetch_all(&state.db)
    .await?;

    // Every entry of the week, in one query: the day's value and the week's sum.
    let rows = sqlx::query(
        "SELECT e.habit_id, e.date, e.value FROM entries e
         JOIN habits h ON h.id = e.habit_id
         WHERE h.user_id = ? AND h.archived = 0 AND e.date BETWEEN ? AND ?",
    )
    .bind(auth.user.id)
    .bind(week_start.to_string())
    .bind((week_start + Days::new(6)).to_string())
    .fetch_all(&state.db)
    .await?;
    let today = date.to_string();
    let mut values: HashMap<Uuid, i64> = HashMap::new();
    let mut week_sums: HashMap<Uuid, i64> = HashMap::new();
    for row in rows {
        let habit_id: Uuid = row.get("habit_id");
        let value: i64 = row.get("value");
        *week_sums.entry(habit_id).or_default() += value;
        if row.get::<String, _>("date") == today {
            values.insert(habit_id, value);
        }
    }

    let habits: Vec<Value> = habits
        .iter()
        .map(|habit| {
            let value = values.get(&habit.id).copied().unwrap_or(0);
            let period_value = if habit.schedule == "weekly" {
                week_sums.get(&habit.id).copied().unwrap_or(0)
            } else {
                value
            };
            json!({
                "id": habit.id,
                "name": habit.name,
                "kind": habit.kind,
                "schedule": habit.schedule,
                "weekdays": habit.weekdays.map(mask_to_weekdays),
                "goal": habit.goal,
                "due": is_due(habit.weekdays, date),
                "value": value,
                "period_value": period_value,
                "done": period_value >= habit.goal,
            })
        })
        .collect();

    Ok(Json(json!({
        "date": today,
        "week_start_date": week_start.to_string(),
        "habits": habits,
    })))
}

#[derive(Deserialize)]
pub struct EntriesQuery {
    from: Option<String>,
    to: Option<String>,
    habit_id: Option<String>,
}

pub async fn list(
    State(state): State<AppState>,
    auth: AuthUser,
    Query(query): Query<EntriesQuery>,
) -> ApiResult<Json<Value>> {
    let (Some(from), Some(to)) = (&query.from, &query.to) else {
        return Err(ApiError::bad_request("from and to are required"));
    };
    let (from, to) = (parse_date(from)?, parse_date(to)?);
    if from > to {
        return Err(ApiError::validation("from must not be after to"));
    }
    if (to - from).num_days() >= MAX_RANGE_DAYS {
        return Err(ApiError::validation("the date range must be at most 366 days"));
    }
    let habit_id = match &query.habit_id {
        Some(raw) => Some(habits::find(&state.db, auth.user.id, raw).await?.id),
        None => None,
    };

    let rows = sqlx::query(
        "SELECT e.habit_id, e.date, e.value FROM entries e
         JOIN habits h ON h.id = e.habit_id
         WHERE h.user_id = ?1 AND e.date BETWEEN ?2 AND ?3 AND (?4 IS NULL OR e.habit_id = ?4)
         ORDER BY e.date, h.position",
    )
    .bind(auth.user.id)
    .bind(from.to_string())
    .bind(to.to_string())
    .bind(habit_id)
    .fetch_all(&state.db)
    .await?;
    let entries: Vec<Value> = rows
        .iter()
        .map(|row| {
            json!({
                "habit_id": row.get::<Uuid, _>("habit_id"),
                "date": row.get::<String, _>("date"),
                "value": row.get::<i64, _>("value"),
            })
        })
        .collect();
    Ok(Json(json!(entries)))
}
