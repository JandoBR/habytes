use std::collections::{BTreeMap, HashMap};

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
    streak::{Rules, Streaks, streaks},
    util::now,
};

/// The longest range `GET /entries` will return, in days, inclusive.
const MAX_RANGE_DAYS: i64 = 366;

fn rules(habit: &Habit, week_start: i64) -> Rules {
    Rules {
        weekly: habit.schedule == "weekly",
        weekdays: habit.weekdays,
        goal: habit.goal,
        week_start,
    }
}

/// The last day of the week containing `date`.
fn week_end(date: NaiveDate, week_start: i64) -> NaiveDate {
    week_start_date(date, week_start) + Days::new(6)
}

/// One habit's status on one day, as returned by every write.
pub async fn status(
    conn: &mut SqliteConnection,
    habit: &Habit,
    week_start: i64,
    date: NaiveDate,
) -> sqlx::Result<Value> {
    // The habit's whole history up to the end of the day's week: streaks need all of it.
    let rows = sqlx::query("SELECT date, value FROM entries WHERE habit_id = ? AND date <= ?")
        .bind(habit.id)
        .bind(week_end(date, week_start).to_string())
        .fetch_all(&mut *conn)
        .await?;
    let entries: BTreeMap<NaiveDate, i64> = rows
        .iter()
        .filter_map(|row| Some((row.get::<String, _>("date").parse().ok()?, row.get("value"))))
        .collect();
    Ok(status_json(habit, week_start, date, &entries))
}

/// The status fields shared by writes and `/today`, from a habit's values by day.
fn status_fields(
    habit: &Habit,
    week_start: i64,
    date: NaiveDate,
    entries: &BTreeMap<NaiveDate, i64>,
) -> (i64, i64, Streaks) {
    let value = entries.get(&date).copied().unwrap_or(0);
    let period_value = if habit.schedule == "weekly" {
        let start = week_start_date(date, week_start);
        entries.range(start..=start + Days::new(6)).map(|(_, value)| value).sum()
    } else {
        value
    };
    // A weekly habit is measured on its whole week, so its streak is too.
    let as_of = if habit.schedule == "weekly" { week_end(date, week_start) } else { date };
    (value, period_value, streaks(&rules(habit, week_start), entries, as_of))
}

fn status_json(
    habit: &Habit,
    week_start: i64,
    date: NaiveDate,
    entries: &BTreeMap<NaiveDate, i64>,
) -> Value {
    let (value, period_value, streaks) = status_fields(habit, week_start, date, entries);
    json!({
        "habit_id": habit.id,
        "date": date.to_string(),
        "value": value,
        "period_value": period_value,
        "done": period_value >= habit.goal,
        "streak": streaks.current,
        "best_streak": streaks.best,
    })
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

    // Every entry up to the end of the week, in one query: streaks need the whole history.
    let rows = sqlx::query(
        "SELECT e.habit_id, e.date, e.value FROM entries e
         JOIN habits h ON h.id = e.habit_id
         WHERE h.user_id = ? AND h.archived = 0 AND e.date <= ?",
    )
    .bind(auth.user.id)
    .bind((week_start + Days::new(6)).to_string())
    .fetch_all(&state.db)
    .await?;
    let mut entries: HashMap<Uuid, BTreeMap<NaiveDate, i64>> = HashMap::new();
    for row in rows {
        if let Ok(day) = row.get::<String, _>("date").parse() {
            entries.entry(row.get("habit_id")).or_default().insert(day, row.get("value"));
        }
    }
    let none = BTreeMap::new();

    let habits: Vec<Value> = habits
        .iter()
        .map(|habit| {
            let (value, period_value, streaks) = status_fields(
                habit,
                auth.user.week_start,
                date,
                entries.get(&habit.id).unwrap_or(&none),
            );
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
                "streak": streaks.current,
                "best_streak": streaks.best,
            })
        })
        .collect();

    Ok(Json(json!({
        "date": date.to_string(),
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
