use std::collections::{BTreeMap, BTreeSet, HashMap};

use axum::{
    Json,
    extract::{Path, Query, State},
};
use chrono::{Days, NaiveDate};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use sqlx::{Row, SqliteConnection};
use uuid::Uuid;

use crate::{
    api::{
        categories,
        habits::{self, Habit},
    },
    error::{ApiError, ApiResult},
    extract::{ApiJson, AuthUser},
    schedule::{
        is_due, mask_to_weekdays, max_value, parse_date, parse_writable_date, today_in,
        week_start_date,
    },
    state::AppState,
    streak::{Rules, streaks},
    util::now,
};

/// The longest range `GET /entries` will return, in days, inclusive.
const MAX_RANGE_DAYS: i64 = 366;

/// The longest note one day can carry.
const MAX_NOTE_CHARS: usize = 500;

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

/// One habit's history by day.
#[derive(Default)]
pub struct History {
    values: BTreeMap<NaiveDate, i64>,
    skipped: BTreeSet<NaiveDate>,
    notes: HashMap<NaiveDate, String>,
}

impl History {
    fn add(&mut self, date: NaiveDate, value: i64, skipped: bool, note: String) {
        self.values.insert(date, value);
        if skipped {
            self.skipped.insert(date);
        }
        if !note.is_empty() {
            self.notes.insert(date, note);
        }
    }

    /// The status fields shared by writes and `/today`.
    fn status(&self, habit: &Habit, week_start: i64, date: NaiveDate) -> Map<String, Value> {
        let value = self.values.get(&date).copied().unwrap_or(0);
        let start = week_start_date(date, week_start);
        let week = start..=start + Days::new(6);
        let period_value = if habit.schedule == "weekly" {
            self.values.range(week.clone()).map(|(_, value)| value).sum()
        } else {
            value
        };
        // A weekly habit is measured on its whole week, so its streak is too.
        let as_of = if habit.schedule == "weekly" { *week.end() } else { date };
        let streaks = streaks(&rules(habit, week_start), &self.values, &self.skipped, as_of);

        let mut fields = Map::new();
        fields.insert("value".into(), json!(value));
        fields.insert("period_value".into(), json!(period_value));
        fields.insert("done".into(), json!(period_value >= habit.goal));
        fields.insert("skipped".into(), json!(self.skipped.contains(&date)));
        fields.insert("note".into(), json!(self.notes.get(&date).map_or("", String::as_str)));
        fields.insert("streak".into(), json!(streaks.current));
        fields.insert("best_streak".into(), json!(streaks.best));
        fields
    }

    /// Each day of the week containing `date`: its value and whether it was skipped.
    fn week(&self, week_start: i64, date: NaiveDate) -> (Vec<i64>, Vec<bool>) {
        let start = week_start_date(date, week_start);
        (0..7)
            .map(|offset| start + Days::new(offset))
            .map(|day| (self.values.get(&day).copied().unwrap_or(0), self.skipped.contains(&day)))
            .unzip()
    }
}

/// One habit's status on one day, as returned by every write.
pub async fn status(
    conn: &mut SqliteConnection,
    habit: &Habit,
    week_start: i64,
    date: NaiveDate,
) -> sqlx::Result<Value> {
    // The habit's whole history up to the end of the day's week: streaks need all of it.
    let rows = sqlx::query(
        "SELECT date, value, skipped, note FROM entries WHERE habit_id = ? AND date <= ?",
    )
    .bind(habit.id)
    .bind(week_end(date, week_start).to_string())
    .fetch_all(&mut *conn)
    .await?;
    let mut history = History::default();
    for row in rows {
        if let Ok(day) = row.get::<String, _>("date").parse() {
            history.add(day, row.get("value"), row.get("skipped"), row.get("note"));
        }
    }
    let mut status = history.status(habit, week_start, date);
    status.insert("habit_id".into(), json!(habit.id));
    status.insert("date".into(), json!(date.to_string()));
    Ok(Value::Object(status))
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

/// What a write may change about one day. Fields left out keep their value.
#[derive(Default)]
pub struct DayChange {
    pub value: Option<i64>,
    pub skipped: Option<bool>,
    pub note: Option<String>,
}

/// Changes one day; the value is clamped to what the habit's kind allows.
pub async fn apply_change(
    conn: &mut SqliteConnection,
    habit: &Habit,
    date: NaiveDate,
    change: DayChange,
) -> sqlx::Result<()> {
    sqlx::query(
        "INSERT INTO entries (habit_id, date, value, skipped, note, updated_at)
         VALUES (?1, ?2, COALESCE(?3, 0), COALESCE(?4, 0), COALESCE(?5, ''), ?6)
         ON CONFLICT (habit_id, date) DO UPDATE
         SET value = COALESCE(?3, value), skipped = COALESCE(?4, skipped),
             note = COALESCE(?5, note), updated_at = ?6",
    )
    .bind(habit.id)
    .bind(date.to_string())
    .bind(change.value.map(|value| value.clamp(0, max_value(&habit.kind))))
    .bind(change.skipped)
    .bind(change.note)
    .bind(now())
    .execute(&mut *conn)
    .await?;
    Ok(())
}

/// Sets one day's value.
pub async fn apply_set(
    conn: &mut SqliteConnection,
    habit: &Habit,
    date: NaiveDate,
    value: i64,
) -> sqlx::Result<()> {
    apply_change(conn, habit, date, DayChange { value: Some(value), ..Default::default() }).await
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
pub struct SetDay {
    value: Option<i64>,
    skipped: Option<bool>,
    note: Option<String>,
}

pub async fn set(
    State(state): State<AppState>,
    auth: AuthUser,
    Path((id, date)): Path<(String, String)>,
    ApiJson(body): ApiJson<SetDay>,
) -> ApiResult<Json<Value>> {
    let habit = habits::find(&state.db, auth.user.id, &id).await?;
    let date = parse_writable_date(&date)?;
    if body.value.is_none() && body.skipped.is_none() && body.note.is_none() {
        return Err(ApiError::validation("give at least one of value, skipped and note"));
    }
    if body.value.is_some_and(|value| value < 0) {
        return Err(ApiError::validation("value must not be negative"));
    }
    let note = body.note.map(|note| note.trim().to_string());
    if note.as_ref().is_some_and(|note| note.chars().count() > MAX_NOTE_CHARS) {
        return Err(ApiError::validation("note must be at most 500 characters"));
    }

    let mut tx = state.db.begin().await?;
    let change = DayChange { value: body.value, skipped: body.skipped, note };
    apply_change(&mut tx, &habit, date, change).await?;
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
        "SELECT e.habit_id, e.date, e.value, e.skipped, e.note FROM entries e
         JOIN habits h ON h.id = e.habit_id
         WHERE h.user_id = ? AND h.archived = 0 AND e.date <= ?",
    )
    .bind(auth.user.id)
    .bind((week_start + Days::new(6)).to_string())
    .fetch_all(&state.db)
    .await?;
    let mut histories: HashMap<Uuid, History> = HashMap::new();
    for row in rows {
        if let Ok(day) = row.get::<String, _>("date").parse() {
            histories.entry(row.get("habit_id")).or_default().add(
                day,
                row.get("value"),
                row.get("skipped"),
                row.get("note"),
            );
        }
    }
    let none = History::default();

    let habits: Vec<Value> = habits
        .iter()
        .map(|habit| {
            let history = histories.get(&habit.id).unwrap_or(&none);
            let mut row = history.status(habit, auth.user.week_start, date);
            let (week_values, week_skipped) = history.week(auth.user.week_start, date);
            row.insert("id".into(), json!(habit.id));
            row.insert("name".into(), json!(habit.name));
            row.insert("kind".into(), json!(habit.kind));
            row.insert("schedule".into(), json!(habit.schedule));
            row.insert("weekdays".into(), json!(habit.weekdays.map(mask_to_weekdays)));
            row.insert("goal".into(), json!(habit.goal));
            row.insert("unit".into(), json!(habit.unit));
            row.insert("color".into(), json!(habit.color));
            row.insert("category_id".into(), json!(habit.category_id));
            row.insert("reminder_time".into(), json!(habit.reminder_time));
            row.insert("due".into(), json!(is_due(habit.weekdays, date)));
            row.insert("week_values".into(), json!(week_values));
            row.insert("week_skipped".into(), json!(week_skipped));
            Value::Object(row)
        })
        .collect();

    Ok(Json(json!({
        "date": date.to_string(),
        "week_start_date": week_start.to_string(),
        "categories": categories::all(&state.db, auth.user.id).await?,
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
        "SELECT e.habit_id, e.date, e.value, e.skipped, e.note FROM entries e
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
                "skipped": row.get::<bool, _>("skipped"),
                "note": row.get::<String, _>("note"),
            })
        })
        .collect();
    Ok(Json(json!(entries)))
}
