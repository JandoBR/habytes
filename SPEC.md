---
id: Spec
aliases: []
tags: []
---

# Habit Tracker — Specification (MVP)

Supersedes `Design Document.md`.

## 1. Overview

A self-hostable habit tracker whose main interface is a **home-screen widget**.

* `habitd` — a single Rust binary with a SQLite file. It serves the JSON API, the webhook endpoints and the web app.
* **Web app** — the full management UI (create, edit, reorder, archive, history, tokens, webhooks).
* **Android app** — signs in and hosts the widget. Anything beyond that is a bonus of sharing the web codebase.
* **Android widget** — shows which habits are due and whether each is completed, and records progress with one tap, online or offline.

### Goals

* Simple deployment: one binary, one database file, one config file.
* One-tap logging from the home screen that never loses a tap.
* Logging by tapping the phone on an NFC tag, handled by the app itself.
* Automation-friendly: every action is available over the API, plus per-habit webhooks for things that are not the phone (Home Assistant, scripts).
* Flexible schedules from the start: daily, specific weekdays, or a weekly target, for both boolean and counter habits.
* Authentication delegated to the existing OIDC provider. This deployment uses **Pocket ID**; any standard provider works.

### Non-goals

* Gamification (coins, rewards, shops).
* Complex recurrence: monthly, every N days, custom intervals.
* iOS app and widget (not targeted for now).
* Reminders and push notifications.
* Linux desktop client.
* A general offline sync engine (see section 9 for what replaces it).
* Social features, sharing, multi-user groups.
* Multiple OIDC issuers, local password accounts.
* Cloud hosting, plugins.

## 2. Architecture

```
  Web browser            Android app (Flutter)       Android widget (Kotlin)
  Flutter web            sign-in, settings           today cache + outbox
       │ cookie                │ bearer token              │ bearer token
       └───────────────┬───────┴───────────────────────────┘
                       ▼
               habitd (Rust, Axum)  ◄──── POST /hook/{secret}  (automation)
                 ├── /api/v1/*   JSON API
                 ├── /auth/*     OIDC login, token exchange
                 ├── /hook/*     webhooks
                 └── /*          embedded web app
                       │
                    SQLite (WAL)             Pocket ID (OIDC provider)
```

The server is the only source of truth. Clients hold no database: the web app is online-only, and the widget keeps a small cache of today plus a queue of unsent taps.

## 3. Technology

| Part | Choice |
| --- | --- |
| Server | Rust, Axum, Tokio, SQLx (SQLite), Serde, `openidconnect`, `chrono` + `chrono-tz`, `rust-embed` |
| Web + Android app | Flutter (Dart), Riverpod, `go_router`, `http`, `flutter_web_auth_2`, `nfc_manager` (tag writing) |
| Android widget | Kotlin, Jetpack Glance, WorkManager. Min SDK 26 |

One Flutter codebase builds the web app and the Android app. The widget is native Kotlin inside the Flutter project's `android/` folder and does its own networking; it does not start a Flutter engine.

### Repository layout

```
habit-tracker/
  SPEC.md
  server/            crate `habitd`
    migrations/      SQLx migrations, embedded and run at startup
    src/
  app/               Flutter project
    lib/
    web/
    android/         includes the Glance widget
```

A release build runs `flutter build web` and embeds the output into `habitd` with `rust-embed`. A Cargo feature (`embed-web`, on by default) lets the server build without it.

## 4. Data model

Conventions:

* IDs are UUIDv7, stored as `BLOB(16)`, written as lowercase hyphenated strings in the API. Clients may supply the ID when creating a habit.
* Timestamps are Unix seconds (`INTEGER`) in the database and RFC 3339 UTC strings in the API.
* Dates are `YYYY-MM-DD` strings with no time zone: the calendar day the user experienced.
* Connections set `journal_mode=WAL`, `foreign_keys=ON`, `busy_timeout=5000`.

```sql
CREATE TABLE users (
  id          BLOB PRIMARY KEY NOT NULL,
  oidc_sub    TEXT NOT NULL UNIQUE,
  username    TEXT NOT NULL,
  timezone    TEXT NOT NULL DEFAULT 'UTC',      -- IANA name
  week_start  INTEGER NOT NULL DEFAULT 1        -- 1 = Monday ... 7 = Sunday
              CHECK (week_start BETWEEN 1 AND 7),
  created_at  INTEGER NOT NULL
) STRICT;

CREATE TABLE habits (
  id              BLOB PRIMARY KEY NOT NULL,
  user_id         BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name            TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  description     TEXT NOT NULL DEFAULT '',
  kind            TEXT NOT NULL CHECK (kind IN ('boolean', 'counter')),
  schedule        TEXT NOT NULL CHECK (schedule IN ('daily', 'weekdays', 'weekly')),
  weekdays        INTEGER                        -- bitmask, bit 0 = Monday ... bit 6 = Sunday
                  CHECK ((schedule = 'weekdays') = (weekdays IS NOT NULL)
                         AND (weekdays IS NULL OR weekdays BETWEEN 1 AND 127)),
  goal            INTEGER NOT NULL DEFAULT 1
                  CHECK (goal >= 1 AND (kind = 'counter'
                         OR (schedule = 'weekly' AND goal <= 7)
                         OR goal = 1)),
  position        INTEGER NOT NULL DEFAULT 0,
  archived        INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  webhook_secret  TEXT UNIQUE,                   -- NULL = webhook disabled
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
) STRICT;
CREATE INDEX habits_by_user ON habits (user_id, archived, position);

CREATE TABLE entries (
  habit_id    BLOB NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
  date        TEXT NOT NULL,
  value       INTEGER NOT NULL CHECK (value >= 0),
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (habit_id, date)
) STRICT, WITHOUT ROWID;

CREATE TABLE applied_ops (
  op_id       BLOB PRIMARY KEY NOT NULL,
  habit_id    BLOB NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
  created_at  INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE tokens (
  id            BLOB PRIMARY KEY NOT NULL,
  user_id       BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL CHECK (kind IN ('session', 'device', 'api')),
  name          TEXT NOT NULL,
  token_hash    BLOB NOT NULL UNIQUE,            -- SHA-256 of the token
  created_at    INTEGER NOT NULL,
  last_used_at  INTEGER,
  expires_at    INTEGER                          -- NULL = never
) STRICT;

CREATE TABLE login_flows (
  state           TEXT PRIMARY KEY NOT NULL,
  nonce           TEXT NOT NULL,
  pkce_verifier   TEXT NOT NULL,                 -- for the OIDC provider
  client          TEXT NOT NULL CHECK (client IN ('web', 'app')),
  redirect_path   TEXT,                          -- web only
  app_challenge   TEXT,                          -- app only, S256
  app_code_hash   BLOB UNIQUE,                   -- app only, set after callback
  user_id         BLOB REFERENCES users(id) ON DELETE CASCADE,
  expires_at      INTEGER NOT NULL
) STRICT;
```

Rules:

* One entry row per habit per day, whatever the schedule. A missing row means 0.
* Boolean values are clamped to 0 or 1 per day. Counter values are clamped to `0..=1_000_000` per day.
* `kind` cannot change after creation. Schedule and goal can.
* Deleting a habit deletes its entries. Archiving hides it from "today" and the widget but keeps history.
* A background task runs hourly and deletes `applied_ops` older than 30 days, expired `tokens` and expired `login_flows`.

### Schedules and completion

Schedule and kind are chosen when the habit is created. Completion is never stored; it is computed from the entries and the habit's current settings.

| Schedule | Due on | Period | `goal` means | Done when |
| --- | --- | --- | --- | --- |
| `daily` | every day | the day | boolean: always 1. Counter: amount per day | the day's value ≥ goal |
| `weekdays` | the days in `weekdays` | the day | same as daily | the day's value ≥ goal |
| `weekly` | every day of the week | the week | boolean: days per week, 1–7. Counter: total per week | the sum of the week's values ≥ goal |

* A week starts on the user's `week_start` day and is evaluated in calendar dates, so no time zone is involved.
* **`value`** is one day's entry. **`period_value`** is what completion is measured on: the same as `value` for `daily` and `weekdays`, the week's sum for `weekly`.
* A `weekdays` habit can still be logged on a day it is not due. The entry is kept, but the habit is not shown in the widget that day.
* Changing a habit's schedule or goal does not touch its entries; past completion is re-evaluated against the new settings.

## 5. Authentication

The server is the OIDC relying party. Clients never see provider tokens; they get a `habitd` credential instead. Who may sign in is decided at the provider.

With Pocket ID: create one OIDC client for `habitd`, set its callback URL to `{public_url}/auth/callback`, and restrict it to the user groups that should have access. `habitd` uses only discovery, the authorization code flow with PKCE, and the ID token, so nothing in it is specific to Pocket ID.

### Credentials

All three kinds live in `tokens`. A token is `hbt_` followed by 32 random bytes in base64url. Only its SHA-256 hash is stored.

| Kind | Used by | Sent as | Lifetime |
| --- | --- | --- | --- |
| `session` | web app | cookie `habitd_session` (HttpOnly, Secure, SameSite=Lax) | 30 days, extended on use |
| `device` | Android app and widget | `Authorization: Bearer` | until revoked |
| `api` | scripts, automation | `Authorization: Bearer` | optional expiry, set at creation |

`last_used_at` is updated at most once a minute per token.

Requests authenticated by cookie that use a mutating method must carry an `Origin` header equal to `public_url`; otherwise the server returns 403. No CORS headers are sent.

### Web login

1. `GET /auth/login?redirect=/some/path` — stores a `login_flows` row (state, nonce, PKCE verifier) and redirects to the provider. `redirect` must be a path starting with a single `/`.
2. `GET /auth/callback?code=&state=` — exchanges the code, validates the ID token (signature, issuer, audience, expiry, nonce), finds or creates the user by `sub`, and refreshes `username` from `preferred_username`, then `email`, then `sub`.
3. Deletes the flow row, sets the session cookie, redirects to `redirect_path`.

On first login the web app sets the user's time zone from the browser. The week starts on Monday unless changed in settings.

### Android login

The only redirect URI registered at the provider is `{public_url}/auth/callback`. The app is handed off through a one-time code protected by its own PKCE pair.

1. The app generates a `code_verifier` and opens `{server}/auth/login?client=app&code_challenge=<S256>` in a Custom Tab.
2. The server runs the same provider flow. On success it stores the user and the hash of a new one-time code on the flow row, gives the row 60 seconds to live, and redirects to `habitd://auth?code=<code>`.
3. The app calls `POST /auth/token` with `{ code, code_verifier, device_name }`.
4. The server checks the code and verifier, deletes the row, and returns `{ token, user }` with a new `device` token.

### Logout

`POST /auth/logout` deletes the credential that made the request. It does not sign the user out of the provider.

## 6. API

Base path `/api/v1`. JSON in and out. All endpoints require a credential except `GET /api/v1/meta`. A user can only see their own data; another user's IDs return 404.

Errors:

```json
{ "error": { "code": "validation_failed", "message": "goal must be at least 1" } }
```

| Status | Code |
| --- | --- |
| 400 | `bad_request` |
| 401 | `unauthenticated` |
| 403 | `forbidden` |
| 404 | `not_found` |
| 409 | `conflict` |
| 422 | `validation_failed` |
| 429 | `rate_limited` |
| 500 | `internal` |

### Meta and user

| Method and path | Purpose |
| --- | --- |
| `GET /meta` | `{ "name": "habitd", "version": "0.1.0", "api_version": 1 }`. The Android app calls this to check a server URL. |
| `GET /me` | `{ id, username, timezone, week_start }` |
| `PATCH /me` | Any of `timezone` (a valid IANA name) and `week_start` (1–7). |

### Habits

Habit object:

```json
{
  "id": "0195c1d2-7b3a-7c1e-9f00-2a4b6c8d0e1f",
  "name": "Drink water",
  "description": "",
  "kind": "counter",
  "schedule": "weekdays",
  "weekdays": [1, 2, 3, 4, 5],
  "goal": 8,
  "position": 2,
  "archived": false,
  "webhook_url": null,
  "created_at": "2026-10-04T09:12:00Z",
  "updated_at": "2026-10-04T09:12:00Z"
}
```

`weekdays` is a list of day numbers (1 = Monday … 7 = Sunday) in the API and a bitmask in the database. It is required for `schedule: "weekdays"` and `null` otherwise.

| Method and path | Purpose |
| --- | --- |
| `GET /habits?archived=false\|true\|all` | List, ordered by `position`. Default `false`. |
| `POST /habits` | Body `{ id?, name, description?, kind, schedule, weekdays?, goal? }`. New habits go last. 409 if `id` exists. |
| `GET /habits/{id}` | One habit. |
| `PATCH /habits/{id}` | Any of `name`, `description`, `schedule`, `weekdays`, `goal`, `archived`. The result must satisfy the goal rules in section 4. |
| `DELETE /habits/{id}` | Deletes the habit and its entries. |
| `PUT /habits/order` | Body `{ "ids": [...] }` listing every non-archived habit once. Sets `position` to the index. |
| `POST /habits/{id}/webhook` | Creates or rotates the webhook secret. Returns `{ "webhook_url": "..." }`. |
| `DELETE /habits/{id}/webhook` | Disables the webhook. |

### Entries

Status object, returned by every write and by `/today`:

```json
{ "habit_id": "...", "date": "2026-10-04", "value": 1, "period_value": 2, "done": false,
  "streak": 4, "best_streak": 9 }
```

`streak` is how many periods in a row the habit has been done, and `best_streak` the longest such run ever. A period is a due day for `daily` and `weekdays` habits and a week for `weekly` ones; days a `weekdays` habit is not due neither count nor break a streak. The running period does not break one either: a streak ends only once a period has passed without the habit being done.

| Method and path | Purpose |
| --- | --- |
| `GET /today?date=YYYY-MM-DD` | Non-archived habits in order with their status for that day: `{ "date": "...", "week_start_date": "...", "habits": [{ id, name, kind, schedule, weekdays, goal, due, value, period_value, done, streak, best_streak }] }`. `due` is false only for a `weekdays` habit on a day outside its mask. `week_start_date` is the first day of the week containing `date`. `date` defaults to today in the user's time zone. This is the widget's read endpoint. |
| `GET /entries?from=&to=&habit_id=` | Raw entries `{ habit_id, date, value }` in an inclusive date range of at most 366 days. `habit_id` is optional. Days with no row are omitted. |
| `POST /habits/{id}/entries/{date}/increment` | Body `{ "op_id": "<uuid>", "delta": 1 }`. Returns the status. |
| `PUT /habits/{id}/entries/{date}` | Body `{ "value": 5 }`. Returns the status. |

Semantics:

* **Increment** is the operation for taps on counters. `delta` is a non-zero integer in `-1000..=1000`. In one transaction the server inserts `op_id` into `applied_ops` and adds `delta` to the value, clamping the result. If `op_id` was already applied it changes nothing and returns the current status with 200. Retrying is therefore always safe, and increments from several devices add up.
* **Set** is the operation for boolean check/uncheck and for corrections. It sets one day's value, never the week's total. It is idempotent; the last request to arrive wins.
* `date` must be a real calendar date no later than tomorrow (UTC).

### Tokens

| Method and path | Purpose |
| --- | --- |
| `GET /tokens` | All of the user's tokens: `{ id, kind, name, created_at, last_used_at, expires_at, current }`. Never the secret. |
| `POST /tokens` | Body `{ name, expires_in_days? }`. Creates an `api` token and returns the secret once. |
| `DELETE /tokens/{id}` | Revokes any token, including a session or device. |

## 7. Webhooks

Webhooks are for automations that run somewhere other than the phone: Home Assistant, a smart button, a script. NFC tags do not use them; the app handles tags directly (section 9).

`POST /hook/{secret}` needs no other authentication. The secret is 32 random bytes in base64url and identifies one habit.

* Counter habit: adds `delta` (query parameter, default 1) to today's value.
* Boolean habit: checks today. For a weekly boolean that is one more day towards the week's goal.
* "Today" is the current date in the owner's time zone.
* Returns 200 with the status. Unknown secret returns 404.
* Only `POST` is accepted, so link previews and prefetchers cannot trigger it.

The secret is stored in plain text so the web app can show the URL again. It grants nothing beyond incrementing that habit and can be rotated or disabled at any time.

Rate limits, held in memory: 60 requests a minute per webhook secret, 20 a minute per IP on `/auth/*`.

## 8. Web app

Online-only. Served by `habitd` from the same origin, so it uses the session cookie.

| Screen | Contents |
| --- | --- |
| Today | Habits due today in order, each showing done or not and its progress (`3/8` today, or `2/3 this week`). Check or uncheck booleans; `+` and `−` on counters. Habits not scheduled today sit in a collapsed section and can still be logged. Previous and next day navigation to fix past days. |
| Habit editor | Create and edit name, description, kind (create only), schedule (every day / pick weekdays / weekly target) and goal. The goal field is labelled by the combination: "per day", "days per week" or "total per week". Archive, delete. |
| Manage | Drag to reorder. Show and restore archived habits. |
| History | Per habit: a calendar heatmap of the last 12 months from `GET /entries`. Days that were not due are greyed out; for weekly habits each week is marked met or missed. Tap a day to set its value. |
| Settings | Time zone and first day of the week. Webhook URL per habit (create, copy, rotate, disable). API tokens (create, revoke). Signed-in devices and sessions (revoke). Sign out. |

An unauthenticated visit redirects to `/auth/login`.

## 9. Android app and widget

### App

Required screens:

1. **Server** — enter the server URL; validated with `GET /meta`.
2. **Sign in** — runs the Android login flow from section 5.
3. **Home** — signed-in user, server, widget setup hint, "Refresh widget", "Sign out".

Because the codebase is shared, the Today screen from the web app is also shown in the Android app, using the device token. The other web screens are optional there.

### Native store

Credentials and widget state are owned by Kotlin code so the widget can use them without Flutter. They live in app-private storage, excluded from backups.

Dart reaches the store through one method channel, `habitd/native`:

| Method | Purpose |
| --- | --- |
| `saveCredentials(serverUrl, token)` | After sign-in. |
| `getCredentials()` | For the Dart API client. |
| `clearCredentials()` | On sign-out. Also clears cache and outbox. |
| `refreshWidgets()` | Fetch and redraw. |

State:

```
cache:  { date, week_start_date, fetched_at,
          habits: [{ id, name, kind, schedule, weekdays, goal, value, period_value, streak }] }
outbox: [{ op_id, habit_id, date, type: "increment" | "set", delta | value }]
```

### What the widget shows

One resizable, scrollable list built with Glance. It lists the habits that are due today, in order. Each row shows the name, whether the habit is **completed**, and its progress. Completed rows are visibly distinct (filled check, dimmed text).

| Habit | Row shows | Completed when | Tap |
| --- | --- | --- | --- |
| Boolean, `daily` or `weekdays` | checkbox | checked today | toggles today |
| Counter, `daily` or `weekdays` | `3/8` | today's value ≥ goal | adds 1 to today |
| Boolean, `weekly` | checkbox for today and `2/3 this week` | days checked this week ≥ goal | toggles today |
| Counter, `weekly` | `12/20 this week` | this week's total ≥ goal | adds 1 to today |

* A `weekdays` habit is hidden on days it is not due.
* A weekly habit stays in the list all week, including after it is completed. A completed weekly boolean still shows whether today is checked.
* Counters keep counting past the goal. Lowering a counter is done in the app or on the web.
* If nothing is due, the widget says so. If the user is signed out, it shows "Sign in", which opens the app.

### Tap handling

Taps run a Glance `ActionCallback`:

1. Apply the change to the cache — `value` and `period_value` move together — and redraw at once.
2. Append the operation to the outbox, with the local date at the moment of the tap and a fresh `op_id`.
3. Try to flush.

**Flush** sends outbox operations in order.

* 2xx: remove it.
* 404 or 422: remove it (the habit is gone or the request can never succeed).
* 401: stop, mark the widget signed out, keep the outbox.
* Network error, 429 or 5xx: stop and retry later.
* After a flush, `GET /today?date=<local date>`, replace the cache, then re-apply whatever is still in the outbox on top of it.

Retries use a WorkManager job that requires a network connection. A periodic job refreshes every 30 minutes, and the app refreshes on launch.

Conflicts need no resolution logic: increments are additive and deduplicated by `op_id`, and sets are last-write-wins.

### NFC tags

A tag identifies a habit; the app does the logging with its own device token. The tag holds no secret, so reading or copying it gives nothing to anyone else.

**Tag contents** (NDEF):

1. A URI record: `habitd://habit/<habit id>`.
2. An Android Application Record with the app's package name, so Android always hands the tag to this app.

**Writing**: the habit editor in the Android app has "Write NFC tag". It writes the two records to any NDEF-capable tag (NTAG213 or larger). Several tags may point to the same habit.

**Scanning**: Android delivers the tag to a small Kotlin activity with no UI. It:

1. Reads the habit ID and looks the habit up in the cache.
2. Queues an operation in the same outbox the widget uses: **set today to 1** for a boolean habit, **add 1** for a counter.
3. Updates the cache, redraws the widget, and confirms with a vibration and a short toast ("Drink water 4/8").
4. Flushes the outbox and finishes.

* It works offline, exactly like a widget tap.
* A boolean scan never unchecks, so scanning twice is harmless. For counters, a second scan of the same habit within 1 second is ignored.
* If the habit is not in the cache (archived, deleted, or not yet fetched), the app refreshes once and otherwise shows "Unknown habit".
* If the user is signed out, the scan opens the sign-in screen.
* Android only reads tags while the phone is unlocked.

### Day and week change

If the cache's date is not the local date, the widget redraws from the cache without waiting for the network, then refreshes:

* Every `value` becomes 0.
* `period_value` becomes 0 too, except for weekly habits when the local date is still within the seven days starting at `week_start_date`.
* Which `weekdays` habits are due is recomputed from the local weekday.

## 10. Deployment

```
habitd
habits.db
config.toml
```

```toml
database_path = "habits.db"
bind_address  = "0.0.0.0:8080"
public_url    = "https://habits.example.com"

[oidc]
issuer        = "https://id.example.com"       # Pocket ID base URL
client_id     = "..."                          # from the Pocket ID client
client_secret = "..."                          # omit for a public client
scopes        = ["openid", "profile", "email"]
```

* Every key can be overridden by an environment variable: `HABITD_DATABASE_PATH`, `HABITD_OIDC__CLIENT_SECRET`, and so on.
* `habitd` serves plain HTTP. TLS is the reverse proxy's job, and `public_url` must be `https` outside local development.
* Migrations run at startup.
* Backup: `sqlite3 habits.db ".backup backup.db"` while running, or copy the file while stopped.
* Logs go to stdout via `tracing`. Tokens, webhook secrets and authorization codes are never logged.

## 11. Testing

* Server: integration tests drive the Axum router against an in-memory SQLite database. They cover completion for every schedule and kind combination, week boundaries for each `week_start`, increment idempotency, clamping, ownership checks (404 for other users' IDs), token expiry and revocation, the `Origin` check, and webhook behaviour per kind.
* OIDC: tested against a mock issuer serving discovery, JWKS and the token endpoint.
* Widget: Kotlin unit tests for the cache and outbox logic (optimistic apply, flush outcomes, day and week change, due-day filtering, re-apply after refresh) and for NFC scans (boolean set, counter debounce, unknown habit).

## 12. Milestones

1. **Server foundation** — config, migrations, OIDC web login, sessions, tokens, `/meta`, `/me`.
2. **Habits and entries** — habits CRUD with schedules, ordering, completion logic, `/today`, `/entries`, increment and set, webhooks, rate limits.
3. **Web app** — all screens in section 8, embedded in the binary.
4. **Android app** — server URL, login, native store, Home and Today screens.
5. **Android widget**.
6. **NFC** — tag writing in the app, scan activity.

## 13. Later

* Statistics beyond streaks.
* Reminders and notifications.
* iOS app and widget.
* Monthly and interval schedules.
* Tags.
* Import and export.
* HMAC-signed webhooks.
