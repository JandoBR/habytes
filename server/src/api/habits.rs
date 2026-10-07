use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::{
    error::{ApiError, ApiResult},
    extract::{ApiJson, AuthUser, parse_id},
    schedule::{
        Period, mask_to_weekdays, parse_date, today_in, validate_every, validate_goal,
        weekdays_to_mask,
    },
    state::AppState,
    util::{now, random_secret, rfc3339},
};

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct Habit {
    pub id: Uuid,
    pub user_id: Uuid,
    pub name: String,
    pub description: String,
    pub kind: String,
    pub schedule: String,
    /// How many weeks, months or years a target's period spans, or the days
    /// of an interval.
    pub every: i64,
    pub weekdays: Option<i64>,
    pub goal: i64,
    pub position: i64,
    pub archived: bool,
    pub webhook_secret: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub unit: String,
    pub color: String,
    pub category_id: Option<Uuid>,
    /// A JSON list of [`Reminder`]s.
    pub reminders: String,
    /// The day the schedule was set, `YYYY-MM-DD`; none for older habits.
    pub anchor: Option<String>,
}

/// The inks a habit can be drawn in.
const COLORS: [&str; 6] = ["ink", "red", "green", "violet", "orange", "teal"];

impl Habit {
    /// What the goal is measured over.
    pub fn period(&self) -> Period {
        let anchor = self.anchor.as_deref().and_then(|anchor| parse_date(anchor).ok());
        Period::of(&self.schedule, self.every).anchored(anchor)
    }

    pub fn webhook_url(&self, public_url: &str) -> Option<String> {
        self.webhook_secret.as_ref().map(|secret| format!("{public_url}/hook/{secret}"))
    }

    /// The reminders as stored, for the API.
    pub fn reminders_json(&self) -> Value {
        serde_json::from_str(&self.reminders).unwrap_or_else(|_| json!([]))
    }

    fn to_json(&self, public_url: &str) -> Value {
        json!({
            "id": self.id,
            "name": self.name,
            "description": self.description,
            "kind": self.kind,
            "schedule": self.schedule,
            "every": self.every,
            "anchor": self.anchor,
            "weekdays": self.weekdays.map(mask_to_weekdays),
            "goal": self.goal,
            "unit": self.unit,
            "color": self.color,
            "category_id": self.category_id,
            "reminders": self.reminders_json(),
            "position": self.position,
            "archived": self.archived,
            "webhook_url": self.webhook_url(public_url),
            "created_at": rfc3339(self.created_at),
            "updated_at": rfc3339(self.updated_at),
        })
    }
}

/// Loads one of the user's habits; anyone else's ID is a 404.
pub async fn find(db: &SqlitePool, user_id: Uuid, raw_id: &str) -> ApiResult<Habit> {
    sqlx::query_as("SELECT * FROM habits WHERE id = ? AND user_id = ?")
        .bind(parse_id(raw_id)?)
        .bind(user_id)
        .fetch_optional(db)
        .await?
        .ok_or(ApiError::NotFound)
}

fn validate_name(name: &str) -> ApiResult<String> {
    let name = name.trim();
    if !(1..=100).contains(&name.chars().count()) {
        return Err(ApiError::validation("name must be between 1 and 100 characters"));
    }
    Ok(name.to_string())
}

fn validate_description(description: &str) -> ApiResult<()> {
    if description.chars().count() > 2000 {
        return Err(ApiError::validation("description must be at most 2000 characters"));
    }
    Ok(())
}

fn validate_unit(unit: &str) -> ApiResult<String> {
    let unit = unit.trim();
    if unit.chars().count() > 20 {
        return Err(ApiError::validation("unit must be at most 20 characters"));
    }
    Ok(unit.to_string())
}

fn validate_color(color: &str) -> ApiResult<()> {
    if !COLORS.contains(&color) {
        return Err(ApiError::validation(format!("color must be one of {}", COLORS.join(", "))));
    }
    Ok(())
}

/// When to remind about a habit: a local time of day, on every day or only
/// on some weekdays (1 = Monday ... 7 = Sunday).
#[derive(Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct Reminder {
    time: String,
    #[serde(default)]
    days: Option<Vec<i64>>,
}

/// The most reminders one habit can have.
const MAX_REMINDERS: usize = 12;

/// Checks a habit's reminders and returns them as they are stored: sorted,
/// without duplicates, and with "every day" always written as no days at all.
fn validate_reminders(mut reminders: Vec<Reminder>) -> ApiResult<String> {
    if reminders.len() > MAX_REMINDERS {
        return Err(ApiError::validation("a habit can have at most 12 reminders"));
    }
    for reminder in &mut reminders {
        let time = &reminder.time;
        let valid = time.len() == 5
            && chrono::NaiveTime::parse_from_str(time, "%H:%M").is_ok()
            && time.bytes().all(|b| b.is_ascii_digit() || b == b':');
        if !valid {
            return Err(ApiError::validation("a reminder's time must be a time of day, HH:MM"));
        }
        if let Some(days) = &mut reminder.days {
            // Checks the numbers; the mask itself is not needed.
            weekdays_to_mask(days).map_err(|_| {
                ApiError::validation("a reminder's days must be numbers from 1 to 7")
            })?;
            days.sort_unstable();
            days.dedup();
            if days.len() == 7 {
                reminder.days = None;
            }
        }
    }
    reminders.sort();
    reminders.dedup();
    Ok(serde_json::to_string(&reminders).expect("reminders serialise"))
}

/// A habit can only go into one of its owner's categories.
async fn validate_category(db: &SqlitePool, user_id: Uuid, category: Uuid) -> ApiResult<()> {
    let found: Option<i64> =
        sqlx::query_scalar("SELECT 1 FROM categories WHERE id = ? AND user_id = ?")
            .bind(category)
            .bind(user_id)
            .fetch_optional(db)
            .await?;
    found
        .map(|_| ())
        .ok_or_else(|| ApiError::validation("category_id is not one of your categories"))
}

/// Resolves the weekday mask for a schedule: required for `weekdays`, absent otherwise.
fn resolve_weekdays(schedule: &str, weekdays: Option<&[i64]>) -> ApiResult<Option<i64>> {
    match (schedule, weekdays) {
        ("weekdays", Some(days)) => Ok(Some(weekdays_to_mask(days)?)),
        ("weekdays", None) => {
            Err(ApiError::validation("weekdays is required for a weekdays schedule"))
        }
        ("daily" | "weekly" | "monthly" | "yearly" | "interval", None) => Ok(None),
        ("daily" | "weekly" | "monthly" | "yearly" | "interval", Some(_)) => {
            Err(ApiError::validation("weekdays must be null unless the schedule is weekdays"))
        }
        _ => Err(ApiError::validation(
            "schedule must be daily, weekdays, weekly, monthly, yearly or interval",
        )),
    }
}

#[derive(Deserialize)]
pub struct ListQuery {
    archived: Option<String>,
}

pub async fn list(
    State(state): State<AppState>,
    auth: AuthUser,
    Query(query): Query<ListQuery>,
) -> ApiResult<Json<Value>> {
    let filter = match query.archived.as_deref().unwrap_or("false") {
        "false" => "AND archived = 0",
        "true" => "AND archived = 1",
        "all" => "",
        _ => return Err(ApiError::bad_request("archived must be false, true or all")),
    };
    let habits: Vec<Habit> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT * FROM habits WHERE user_id = ? {filter} ORDER BY archived, position, created_at, id"
    )))
    .bind(auth.user.id)
    .fetch_all(&state.db)
    .await?;
    let public_url = &state.config.public_url;
    Ok(Json(habits.iter().map(|h| h.to_json(public_url)).collect()))
}

/// The position after the user's last active habit.
async fn next_position(db: &SqlitePool, user_id: Uuid) -> sqlx::Result<i64> {
    sqlx::query_scalar(
        "SELECT COALESCE(MAX(position) + 1, 0) FROM habits WHERE user_id = ? AND archived = 0",
    )
    .bind(user_id)
    .fetch_one(db)
    .await
}

#[derive(Deserialize)]
pub struct CreateHabit {
    id: Option<Uuid>,
    name: String,
    #[serde(default)]
    description: String,
    kind: String,
    schedule: String,
    every: Option<i64>,
    weekdays: Option<Vec<i64>>,
    goal: Option<i64>,
    #[serde(default)]
    unit: String,
    color: Option<String>,
    category_id: Option<Uuid>,
    #[serde(default)]
    reminders: Vec<Reminder>,
}

pub async fn create(
    State(state): State<AppState>,
    auth: AuthUser,
    ApiJson(body): ApiJson<CreateHabit>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let name = validate_name(&body.name)?;
    validate_description(&body.description)?;
    if !matches!(body.kind.as_str(), "boolean" | "counter") {
        return Err(ApiError::validation("kind must be boolean or counter"));
    }
    let weekdays = resolve_weekdays(&body.schedule, body.weekdays.as_deref())?;
    let every = body.every.unwrap_or(1);
    validate_every(&body.schedule, every)?;
    let goal = body.goal.unwrap_or(1);
    validate_goal(&body.kind, &body.schedule, every, goal)?;
    let unit = validate_unit(&body.unit)?;
    let color = body.color.unwrap_or_else(|| "ink".into());
    validate_color(&color)?;
    if let Some(category) = body.category_id {
        validate_category(&state.db, auth.user.id, category).await?;
    }
    let reminders = validate_reminders(body.reminders)?;

    let id = body.id.unwrap_or_else(Uuid::now_v7);
    let now = now();
    let position = next_position(&state.db, auth.user.id).await?;
    let result = sqlx::query(
        "INSERT INTO habits (id, user_id, name, description, kind, schedule, every, weekdays,
                             goal, position, created_at, updated_at, unit, color, category_id,
                             reminders, anchor)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (id) DO NOTHING",
    )
    .bind(id)
    .bind(auth.user.id)
    .bind(&name)
    .bind(&body.description)
    .bind(&body.kind)
    .bind(&body.schedule)
    .bind(every)
    .bind(weekdays)
    .bind(goal)
    .bind(position)
    .bind(now)
    .bind(now)
    .bind(&unit)
    .bind(&color)
    .bind(body.category_id)
    .bind(&reminders)
    .bind(today_in(&auth.user.timezone).to_string())
    .execute(&state.db)
    .await?;
    if result.rows_affected() == 0 {
        return Err(ApiError::Conflict("a habit with this id already exists".into()));
    }

    let habit = find(&state.db, auth.user.id, &id.to_string()).await?;
    Ok((StatusCode::CREATED, Json(habit.to_json(&state.config.public_url))))
}

pub async fn get(
    State(state): State<AppState>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let habit = find(&state.db, auth.user.id, &id).await?;
    Ok(Json(habit.to_json(&state.config.public_url)))
}

/// Distinguishes an absent field from an explicit `null`.
fn nullable<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

#[derive(Deserialize)]
pub struct PatchHabit {
    name: Option<String>,
    description: Option<String>,
    schedule: Option<String>,
    every: Option<i64>,
    #[serde(default, deserialize_with = "nullable")]
    weekdays: Option<Option<Vec<i64>>>,
    goal: Option<i64>,
    archived: Option<bool>,
    unit: Option<String>,
    color: Option<String>,
    #[serde(default, deserialize_with = "nullable")]
    category_id: Option<Option<Uuid>>,
    reminders: Option<Vec<Reminder>>,
}

pub async fn patch(
    State(state): State<AppState>,
    auth: AuthUser,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<PatchHabit>,
) -> ApiResult<Json<Value>> {
    let mut habit = find(&state.db, auth.user.id, &id).await?;

    if let Some(name) = &body.name {
        habit.name = validate_name(name)?;
    }
    if let Some(description) = body.description {
        validate_description(&description)?;
        habit.description = description;
    }

    let schedule_changed = body.schedule.as_ref().is_some_and(|s| *s != habit.schedule);
    if let Some(schedule) = body.schedule {
        habit.schedule = schedule;
    }
    habit.weekdays = match body.weekdays {
        Some(weekdays) => resolve_weekdays(&habit.schedule, weekdays.as_deref())?,
        // Moving away from a weekdays schedule drops the days with it.
        None if schedule_changed && habit.schedule != "weekdays" => {
            resolve_weekdays(&habit.schedule, None)?
        }
        None => {
            let current = habit.weekdays.map(mask_to_weekdays);
            resolve_weekdays(&habit.schedule, current.as_deref())?
        }
    };
    // A new schedule starts over at one week, month or year at a time.
    let every_before = habit.every;
    if let Some(every) = body.every.or(schedule_changed.then_some(1)) {
        habit.every = every;
    }
    // And its periods are counted from now.
    if schedule_changed || habit.every != every_before {
        habit.anchor = Some(today_in(&auth.user.timezone).to_string());
    }
    validate_every(&habit.schedule, habit.every)?;
    if let Some(goal) = body.goal {
        habit.goal = goal;
    }
    validate_goal(&habit.kind, &habit.schedule, habit.every, habit.goal)?;

    if let Some(unit) = &body.unit {
        habit.unit = validate_unit(unit)?;
    }
    if let Some(color) = body.color {
        validate_color(&color)?;
        habit.color = color;
    }
    if let Some(category) = body.category_id {
        if let Some(category) = category {
            validate_category(&state.db, auth.user.id, category).await?;
        }
        habit.category_id = category;
    }
    if let Some(reminders) = body.reminders {
        habit.reminders = validate_reminders(reminders)?;
    }

    if let Some(archived) = body.archived {
        if habit.archived && !archived {
            habit.position = next_position(&state.db, auth.user.id).await?;
        }
        habit.archived = archived;
    }

    habit.updated_at = now();
    sqlx::query(
        "UPDATE habits SET name = ?, description = ?, schedule = ?, every = ?, weekdays = ?,
                           goal = ?, position = ?, archived = ?, updated_at = ?, unit = ?, color = ?,
                           category_id = ?, reminders = ?, anchor = ?
         WHERE id = ?",
    )
    .bind(&habit.name)
    .bind(&habit.description)
    .bind(&habit.schedule)
    .bind(habit.every)
    .bind(habit.weekdays)
    .bind(habit.goal)
    .bind(habit.position)
    .bind(habit.archived)
    .bind(habit.updated_at)
    .bind(&habit.unit)
    .bind(&habit.color)
    .bind(habit.category_id)
    .bind(&habit.reminders)
    .bind(&habit.anchor)
    .bind(habit.id)
    .execute(&state.db)
    .await?;
    Ok(Json(habit.to_json(&state.config.public_url)))
}

pub async fn delete(
    State(state): State<AppState>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let habit = find(&state.db, auth.user.id, &id).await?;
    sqlx::query("DELETE FROM habits WHERE id = ?").bind(habit.id).execute(&state.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct Order {
    ids: Vec<Uuid>,
}

pub async fn order(
    State(state): State<AppState>,
    auth: AuthUser,
    ApiJson(body): ApiJson<Order>,
) -> ApiResult<Json<Value>> {
    let mut tx = state.db.begin().await?;
    let mut current: Vec<Uuid> =
        sqlx::query_scalar("SELECT id FROM habits WHERE user_id = ? AND archived = 0")
            .bind(auth.user.id)
            .fetch_all(&mut *tx)
            .await?;
    let mut requested = body.ids.clone();
    current.sort();
    requested.sort();
    if current != requested {
        return Err(ApiError::validation("ids must list every non-archived habit exactly once"));
    }
    for (position, id) in body.ids.iter().enumerate() {
        sqlx::query("UPDATE habits SET position = ? WHERE id = ?")
            .bind(position as i64)
            .bind(id)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(Json(json!({ "ids": body.ids })))
}

pub async fn create_webhook(
    State(state): State<AppState>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let mut habit = find(&state.db, auth.user.id, &id).await?;
    habit.webhook_secret = Some(random_secret());
    sqlx::query("UPDATE habits SET webhook_secret = ? WHERE id = ?")
        .bind(&habit.webhook_secret)
        .bind(habit.id)
        .execute(&state.db)
        .await?;
    Ok(Json(json!({ "webhook_url": habit.webhook_url(&state.config.public_url) })))
}

pub async fn delete_webhook(
    State(state): State<AppState>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let habit = find(&state.db, auth.user.id, &id).await?;
    sqlx::query("UPDATE habits SET webhook_secret = NULL WHERE id = ?")
        .bind(habit.id)
        .execute(&state.db)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}
