---
id: Spec
aliases: []
tags: []
---

# HaBytes — Specification

This describes HaBytes as it is built. `PROGRESS.md` records what has been
verified and what is still open; `README.md` is the short introduction.

## 1. Overview

A self-hostable habit tracker whose main interface is a **home-screen widget**.

* `habitd` — a single Rust binary with a SQLite file. It serves the JSON API, the webhook endpoints and the web app.
* **Web app** — the full interface: log habits, manage them, look back.
* **Android app** — the same screens, plus what only a phone can do: the widget, NFC tags and reminders.
* **Android widget** — shows which habits are due and whether each is done, records progress with one tap, online or offline, and can add a habit.

### Goals

* Simple deployment: one binary, one database file, one config file.
* One-tap logging from the home screen that never loses a tap.
* Logging by tapping the phone on an NFC tag, handled by the app itself.
* Automation-friendly: every action is available over the API, plus per-habit webhooks for things that are not the phone (Home Assistant, scripts).
* Flexible schedules: daily, specific weekdays, every few days counted from when it was last done, or a target over a week, a month, a year or several of them, for both yes/no and counter habits.
* Streaks that are fair: a day off or a skipped day does not break one.
* Authentication delegated to an existing OIDC provider. This deployment uses **Pocket ID**; any standard provider works.

### Non-goals

* Gamification (coins, rewards, shops).
* Complex recurrence: the third Tuesday of the month, every other Friday.
* iOS app and widget.
* Linux desktop client.
* A general offline sync engine (section 10 describes what replaces it).
* Social features, sharing, multi-user groups.
* Multiple OIDC issuers, local password accounts.
* Plugins.

## 2. Architecture

```
  Web browser            Android app (Flutter)       Android widget (Kotlin)
  Flutter web            all screens, NFC writing    today cache + outbox,
       │ cookie                │ bearer token         reminders, quick add
       │                       │                           │ bearer token
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

The server is the only source of truth. Clients hold no database: the web app is online-only, and the phone keeps a small cache of today plus a queue of unsent taps.

## 3. Technology

| Part | Choice |
| --- | --- |
| Server | Rust, Axum, Tokio, SQLx (SQLite), Serde, `openidconnect`, `chrono` + `chrono-tz`, `rust-embed` |
| Web + Android app | Flutter (Dart), Riverpod, `go_router`, `http`, `flutter_web_auth_2`, `nfc_manager` (tag writing) |
| Android native | Kotlin, Jetpack Glance, WorkManager, AlarmManager. Min SDK 26 |

One Flutter codebase builds the web app and the Android app. The widget, NFC scans, quick add and reminders are native Kotlin inside the Flutter project's `android/` folder and do their own networking; none of them starts a Flutter engine.

### Repository layout

```
habit-tracker/
  SPEC.md  PROGRESS.md  README.md
  Dockerfile            habitd with the web app embedded
  flake.nix             the development environment
  scripts/              publish-image, publish-release, make-icons
  .forgejo/workflows/   image.yml, android.yml
  server/               crate `habitd`
    migrations/         SQLx migrations, embedded and run at startup
    src/
  app/                  Flutter project
    lib/
    web/
    android/            widget, NFC, quick add, reminders
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

CREATE TABLE categories (
  id          BLOB PRIMARY KEY NOT NULL,
  user_id     BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 60),
  position    INTEGER NOT NULL DEFAULT 0,
  collapsed   INTEGER NOT NULL DEFAULT 0 CHECK (collapsed IN (0, 1)),
  created_at  INTEGER NOT NULL
) STRICT;

CREATE TABLE habits (
  id              BLOB PRIMARY KEY NOT NULL,
  user_id         BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name            TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  description     TEXT NOT NULL DEFAULT '',
  kind            TEXT NOT NULL CHECK (kind IN ('boolean', 'counter')),
  schedule        TEXT NOT NULL
                  CHECK (schedule IN ('daily', 'weekdays', 'weekly', 'monthly', 'yearly',
                                      'interval')),
  every           INTEGER NOT NULL DEFAULT 1     -- a target's periods counted as one, or an
                                                 -- interval's days; 1 otherwise
                  CHECK (every >= 1
                         AND (every = 1
                              OR schedule IN ('weekly', 'monthly', 'yearly', 'interval'))),
  weekdays        INTEGER                        -- bitmask, bit 0 = Monday ... bit 6 = Sunday
                  CHECK ((schedule = 'weekdays') = (weekdays IS NOT NULL)
                         AND (weekdays IS NULL OR weekdays BETWEEN 1 AND 127)),
  goal            INTEGER NOT NULL DEFAULT 1
                  CHECK (goal >= 1 AND (kind = 'counter'
                         OR (schedule IN ('weekly', 'monthly', 'yearly') AND goal <= 366 * every)
                         OR goal = 1)),
  unit            TEXT NOT NULL DEFAULT '',      -- "pages", "ml"; at most 20 characters
  color           TEXT NOT NULL DEFAULT 'ink',   -- ink, red, green, violet, orange, teal
  category_id     BLOB REFERENCES categories(id) ON DELETE SET NULL,
  reminders       TEXT NOT NULL DEFAULT '[]',    -- JSON: [{ "time": "HH:MM", "days": [1..7] | null }]
  anchor          TEXT,                          -- the day the schedule was set, YYYY-MM-DD
  position        INTEGER NOT NULL DEFAULT 0,
  archived        INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  webhook_secret  TEXT UNIQUE,                   -- NULL = webhook disabled
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
) STRICT;

CREATE TABLE entries (
  habit_id    BLOB NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
  date        TEXT NOT NULL,
  value       INTEGER NOT NULL CHECK (value >= 0),
  skipped     INTEGER NOT NULL DEFAULT 0,        -- the day is excused
  note        TEXT NOT NULL DEFAULT '',          -- at most 500 characters
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

* One entry row per habit per day, whatever the schedule. A missing row means value 0, not skipped, no note.
* Boolean values are clamped to 0 or 1 per day. Counter values are clamped to `0..=1_000_000` per day.
* `kind` cannot change after creation. Everything else about a habit can.
* Deleting a habit deletes its entries. Archiving hides it from Today and the widget but keeps its history.
* Deleting a category keeps its habits, without one.
* A background task runs hourly and deletes `applied_ops` older than 30 days, expired `tokens` and expired `login_flows`.

### Schedules and completion

Schedule and kind are chosen when the habit is created. Completion is never stored; it is computed from the entries and the habit's current settings.

| Schedule | Due on | Period | `goal` means | Done when |
| --- | --- | --- | --- | --- |
| `daily` | every day | the day | boolean: always 1. Counter: amount per day | the day's value ≥ goal |
| `weekdays` | the days in `weekdays` | the day | same as daily | the day's value ≥ goal |
| `interval` | from `every` days after the last day it was done | the day | same as daily | the day's value ≥ goal |
| `weekly`, `monthly`, `yearly` | every day until it is met | `every` weeks, months or years | boolean: days per period. Counter: total per period | the sum of the period's values ≥ goal |

* `weekly`, `monthly` and `yearly` are **targets**: so many times over a period rather than on given days. `every` (1–52, 1 by default and always 1 for `daily` and `weekdays`) makes the period several weeks, months or years: `monthly` with `every: 3` is once a quarter.
* An `interval` habit (`every` from 1 to 365 days) rests after a day it was done on and comes due again `every` days later; it then stays due until it is done. One that was never done is due, and so is a resting one on a day it was logged on anyway.
* A target that is met is no longer due for the rest of its period, except on a day it was logged on. Like any habit that is not due, it can still be logged.
* A week starts on the user's `week_start` day and is evaluated in calendar dates, so no time zone is involved. Periods of several weeks are blocks counted from the week of the habit's `anchor` — the day its schedule or `every` was last set, in the user's time zone — so that the first block is a whole one (habits from before anchors count from the week of 5 January 1970), months are calendar months in blocks counted from January, and years are calendar years.
* A boolean target's goal cannot be more days than its period has: 7 for each week, 30 for each month (365 × `every` / 12, rounded down), 365 for each year.
* **`value`** is one day's entry. **`period_value`** is what completion is measured on: the same as `value` for `daily` and `weekdays`, the sum of the period's values for a target. **`period_start`** and **`period_end`** are the first and last day of that period.
* A `weekdays` habit can still be logged on a day it is not due. The entry is kept, but the habit is not shown in the widget that day.
* Changing a habit's schedule or goal does not touch its entries; past completion is re-evaluated against the new settings.

### Streaks and skipped days

A streak is how many periods in a row a habit has been done: due days for `daily` and `weekdays` habits, whole periods for targets, and for an `interval` habit the times it was done no later than the day it came due. `streak` is the run that includes, or ends right before, the current period; `best_streak` is the longest run ever.

* The period that is still running does not break a streak. It ends only once a period has passed without the habit being done.
* Days a `weekdays` habit is not due neither count nor break one.
* A **skipped** day (ill, travelling) neither counts nor breaks one. For a target, a skipped day excuses its whole period. A period that was skipped but done anyway simply counts as done.
* A target's streak, like its completion, is measured on its whole period.

## 5. Authentication

The server is the OIDC relying party. Clients never see provider tokens; they get a `habitd` credential instead. Who may sign in is decided at the provider.

With Pocket ID: create one OIDC client for `habitd`, set its callback URL to `{public_url}/auth/callback`, and restrict it to the user groups that should have access. `habitd` uses only discovery, the authorization code flow with PKCE, and the ID token, so nothing in it is specific to Pocket ID.

### Credentials

All three kinds live in `tokens`. A token is `hbt_` followed by 32 random bytes in base64url. Only its SHA-256 hash is stored.

| Kind | Used by | Sent as | Lifetime | Named |
| --- | --- | --- | --- | --- |
| `session` | web app | cookie `habitd_session` (HttpOnly, Secure, SameSite=Lax) | 30 days, extended on use | after the browser, e.g. `Firefox on Linux` |
| `device` | Android app, widget | `Authorization: Bearer` | until revoked | by the device, e.g. `POCO X3 GT` |
| `api` | scripts, automation | `Authorization: Bearer` | optional expiry, set at creation | by the user |

`last_used_at` is updated at most once a minute per token.

Signing in again replaces the old credential rather than adding another: a browser that still holds a session cookie has that session replaced, and a device has the earlier token with the same name replaced. Two devices with the same name therefore cannot both stay signed in.

Requests authenticated by cookie that use a mutating method must carry an `Origin` header equal to `public_url`; otherwise the server returns 403. No CORS headers are sent.

### Web login

1. `GET /auth/login?redirect=/some/path` — stores a `login_flows` row (state, nonce, PKCE verifier) and redirects to the provider. `redirect` must be a path starting with a single `/`.
2. `GET /auth/callback?code=&state=` — exchanges the code, validates the ID token (signature, issuer, audience, expiry, nonce), finds or creates the user by `sub`, and refreshes `username` from `preferred_username`, then `email`, then `sub`.
3. Deletes the flow row, sets the session cookie, redirects to `redirect_path`.

A brand-new account starts in UTC; the app sets its time zone from the device on first sign-in, while it has no habits. The week starts on Monday unless changed in Settings.

### Android login

The only redirect URI registered at the provider is `{public_url}/auth/callback`. The app is handed off through a one-time code protected by its own PKCE pair.

1. The app generates a `code_verifier` and opens `{server}/auth/login?client=app&code_challenge=<S256>` in a browser tab.
2. The server runs the same provider flow. On success it stores the user and the hash of a new one-time code on the flow row, gives the row 60 seconds to live, and redirects to `habitd://auth?code=<code>`.
3. The app's own `AuthCallbackActivity` receives that, hands the code to the waiting sign-in and returns to the app, closing the browser tab whichever browser was used.
4. The app calls `POST /auth/token` with `{ code, code_verifier, device_name }`.
5. The server checks the code and verifier, deletes the row, and returns `{ token, user }` with a new `device` token.

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
  "every": 1,
  "anchor": "2026-10-04",
  "weekdays": [1, 2, 3, 4, 5],
  "goal": 8,
  "unit": "glasses",
  "color": "teal",
  "category_id": null,
  "reminders": [{ "time": "18:30", "days": null }, { "time": "07:00", "days": [1, 3, 5] }],
  "position": 2,
  "archived": false,
  "webhook_url": null,
  "created_at": "2026-10-04T09:12:00Z",
  "updated_at": "2026-10-04T09:12:00Z"
}
```

`weekdays` is a list of day numbers (1 = Monday … 7 = Sunday) in the API and a bitmask in the database. It is required for `schedule: "weekdays"` and `null` otherwise. `every` is how many weeks, months or years a target's period spans, or the days of an interval (section 4). `category_id` must be one of the user's own categories. `reminders` is a list of at most 12, each a local time of day and the weekdays it applies on (`null` for every day); it is stored sorted and without duplicates, and an empty list removes them all.

| Method and path | Purpose |
| --- | --- |
| `GET /habits?archived=false\|true\|all` | List, ordered by `position`. Default `false`. |
| `POST /habits` | Body `{ id?, name, description?, kind, schedule, every?, weekdays?, goal?, unit?, color?, category_id?, reminders? }`. New habits go last. 409 if `id` exists. |
| `GET /habits/{id}` | One habit. |
| `PATCH /habits/{id}` | Any of `name`, `description`, `schedule`, `every`, `weekdays`, `goal`, `unit`, `color`, `category_id`, `reminders`, `archived`. A new `schedule` without `every` goes back to 1. The result must satisfy the goal rules in section 4. |
| `DELETE /habits/{id}` | Deletes the habit and its entries. |
| `PUT /habits/order` | Body `{ "ids": [...] }` listing every non-archived habit once. Sets `position` to the index. |
| `POST /habits/{id}/webhook` | Creates or replaces the webhook secret. Returns `{ "webhook_url": "..." }`. |
| `DELETE /habits/{id}/webhook` | Removes the webhook. |

### Categories

`{ id, name, position, collapsed }`. `collapsed` is whether the category is folded away on Today and in the widget; it is stored on the server so every client agrees.

| Method and path | Purpose |
| --- | --- |
| `GET /categories` | List, in order. |
| `POST /categories` | Body `{ name }`. New categories go last. |
| `PATCH /categories/{id}` | Any of `name` and `collapsed`. |
| `DELETE /categories/{id}` | Deletes it; its habits stay, without a category. |
| `PUT /categories/order` | Body `{ "ids": [...] }` listing every category once. |

### Entries

Status object, returned by every write:

```json
{ "habit_id": "...", "date": "2026-10-04", "value": 1, "period_value": 2, "done": false,
  "period_start": "2026-09-28", "period_end": "2026-10-04", "skipped": false, "note": "", "streak": 4, "best_streak": 9 }
```

| Method and path | Purpose |
| --- | --- |
| `GET /today?date=YYYY-MM-DD` | The widget's and Today's read endpoint: `{ date, week_start_date, categories: [...], habits: [...] }`. `date` defaults to today in the user's time zone. Each habit row is the status above plus `id`, `name`, `kind`, `schedule`, `every`, `weekdays`, `goal`, `unit`, `color`, `category_id`, `reminders`, `due`, `due_from`, `week_values` and `week_skipped`. `due` is false for a `weekdays` habit on a day outside its mask, and, with nothing logged that day, an `interval` habit that is resting and a target that is met. `due_from` is the day an `interval` habit comes due again after it was last done before `date`, `null` for one never done and for other schedules. `week_values` and `week_skipped` give each of the week's seven days, from `week_start_date`. Archived habits are left out. |
| `GET /entries?from=&to=&habit_id=` | Raw entries `{ habit_id, date, value, skipped, note }` in an inclusive date range of at most 366 days. `habit_id` is optional. Days with no row are omitted. |
| `POST /habits/{id}/entries/{date}/increment` | Body `{ "op_id": "<uuid>", "delta": 1 }`. Returns the status. |
| `PUT /habits/{id}/entries/{date}` | Body with any of `value`, `skipped` and `note`. What is left out keeps its value. Returns the status. |

Semantics:

* **Increment** is the operation for taps on counters. `delta` is a non-zero integer in `-1000..=1000`. In one transaction the server inserts `op_id` into `applied_ops` and adds `delta` to the value, clamping the result. If `op_id` was already applied it changes nothing and returns the current status with 200. Retrying is therefore always safe, and increments from several devices add up.
* **Set** is the operation for boolean check/uncheck, corrections, skipping a day and notes. It changes one day, never a period's total. It is idempotent; the last request to arrive wins.
* `date` must be a real calendar date no later than tomorrow (UTC).

### Tokens

| Method and path | Purpose |
| --- | --- |
| `GET /tokens` | All of the user's tokens: `{ id, kind, name, created_at, last_used_at, expires_at, current }`. Never the secret. |
| `POST /tokens` | Body `{ name, expires_in_days? }`. Creates an `api` token and returns the secret once. |
| `DELETE /tokens/{id}` | Revokes any token, including a session or device. |

## 7. Webhooks

Webhooks are for automations that run somewhere other than the phone: Home Assistant, a smart button, a script. NFC tags do not use them; the app handles tags directly (section 10).

`POST /hook/{secret}` needs no other authentication. The secret is 32 random bytes in base64url and identifies one habit.

* Counter habit: adds `delta` (query parameter, default 1) to today's value.
* Boolean habit: checks today. For a boolean target that is one more day towards the period's goal.
* "Today" is the current date in the owner's time zone.
* Returns 200 with the status. Unknown secret returns 404.
* Only `POST` is accepted, so link previews and prefetchers cannot trigger it.

The secret is stored in plain text so the app can show the URL again. It grants nothing beyond logging that habit and can be replaced or removed at any time.

Rate limits, held in memory: 60 requests a minute per webhook secret, 20 a minute per IP on `/auth/*`. With `trust_forwarded_for` set, the client address is taken from the last entry of `X-Forwarded-For`.

## 8. The app

One Flutter codebase. On the web it is served by `habitd` from the same origin and uses the session cookie; an unauthenticated visit to any page redirects to `/auth/login` and comes back to that page. On Android it uses the device token.

| Screen | Contents |
| --- | --- |
| Today | The day's date with how many habits are done; skipped habits and targets over more than a week are left out of that count, as they are in each category's. Habits due that day, those without a category first, then under their categories; tapping a category's heading folds or unfolds it. Each row has a stamp (square for yes/no, round for counters), the name — highlighted when done —, the week as a strip of seven squares, progress (`5/8 glasses`, `2/3 this week`), the streak once it is at least two, and the day's note. Check or uncheck yes/no habits; `−` and `+` on counters. A sheet behind `⋮` or holding `+` offers `+5`, `+10`, `+25`, another amount, an exact value, a note, and skipping the day. A long-press (or right-click) on a habit opens a quick menu: skip today, that sheet, history, edit, archive, delete. Habits not scheduled that day sit in a folded section and can still be logged. Previous and next day navigation to fix past days. |
| Habit editor | Name, description, kind (create only), schedule (every day / pick weekdays / every few days, with the days between / target — per week, per month, per year, or a custom "every N weeks, months or years"), goal — labelled "per day", "days per month", "total every 2 weeks" and so on —, unit (counters), colour, category (or a new one on the spot) and reminders: any number, each with a time and the days it applies on. For an existing habit: its webhook (create, copy, replace, remove), "Write NFC tag" on Android, archive, delete. |
| Habits | Drag to reorder. Categories: add, rename, reorder, delete. Archived habits, with restore. |
| History | Per habit: current and best streak, completion over the last 30 and 90 days, the weekday it most often gets done on, a bar per week for the last twelve weeks (for a target, a bar for each of its last periods, up to twelve and no further back than a year), a calendar heatmap of the last 12 months, and its notes. In the heatmap, days that were not due or were skipped are greyed, days with a note carry a marked corner, and for targets each period is marked met or missed under the week it ends in. Tap a day to change its value, skip it or edit its note. |
| Settings | Time zone and first day of the week. API tokens (create, revoke). Signed-in devices and sessions (revoke). Sign out. |
| Server, Sign in, Device | Android only: enter the server URL (checked with `GET /meta`), sign in, and see the account and server, the widget hint, "Refresh widget" and "Sign out". |

The statistics on History are worked out in the app from `GET /entries`. A skipped day and a day off are left out of a completion rate; the running day or period is not held against it, and for an `interval` habit the days it was resting are left out too. A target is rated in whole periods, and one that began before the entries the app has is only counted if it was met.

### Look

Flat ink on paper: hairlines instead of shadows, squared corners, and one loud colour used in a single way — as a highlighter over what is done. The default palette, "riso", is blue ink and a yellow highlighter on off-white stock, with a dark counterpart; two others (`ledger`, `graphite`) can be chosen at build time with `--dart-define=PALETTE=`. A habit can be drawn in one of six inks, used for its stamp, week strip and heatmap. Fonts are bundled: Bricolage Grotesque for display, Instrument Sans for text, DM Mono for numbers.

The logo is an H made of bits: seven blocks of a 3×3 grid in ink, with the crossbar block in the highlighter.

On the web, Flutter's semantics tree is always on, so every control is also a real element — for screen readers and for keyboard link-hint extensions.

## 9. Android: the native store

Credentials and the widget's state are owned by Kotlin code so that the widget, NFC scans, quick add and reminders work without Flutter. They live in app-private storage, excluded from backups.

Dart reaches the native side through one method channel, `habitd/native`:

| Method | Purpose |
| --- | --- |
| `saveCredentials(serverUrl, token)` | After sign-in. |
| `getCredentials()` | For the Dart API client. |
| `clearCredentials()` | On sign-out. Also clears the cache and the outbox, and cancels reminders. |
| `refreshWidgets()` | Flush, fetch and redraw. The app calls it on launch, on resume, and after every change. |
| `getTimeZone()`, `getDeviceName()` | The device's IANA time zone and its readable name. |
| `requestNotifications()` | Asks for the notification permission, when a reminder is first set. |
| `muteScans(habitId)` | Makes scans of that habit's tag do nothing for a few seconds, around writing it. |
| `takeLaunchRoute()` | The screen another part of the app asked to open (quick add's "More options"). |

State:

```
cache:  { date, week_start_date, fetched_at,
          categories: [{ id, name, collapsed }],
          habits: [{ id, name, kind, schedule, every, weekdays, goal, unit, value, period_value,
                     period_start, period_end, due_from, streak, skipped, category_id, reminders }] }
outbox: [{ op_id, habit_id, date, type: "increment" | "set", delta | value }]
```

## 10. Android: widget, NFC, quick add, reminders

### What the widget shows

One resizable, scrollable list built with Glance, in the app's palette (light or dark with the system). A header gives the day, how many habits are done, and a `+`. Below it are the habits due today: those without a category first, then each category under its heading and count. A folded category shows only its heading.

| Habit | Row shows | Marked when | Tap |
| --- | --- | --- | --- |
| Boolean, `daily` or `weekdays` | square stamp | checked today | toggles today |
| Counter, `daily` or `weekdays` | round stamp, `3/8 glasses` | today's value ≥ goal | adds 1 to today |
| Boolean target | square stamp for today, `2/3 this week` | checked today | toggles today |
| Counter target | round stamp, `12/20 this month` | the period's total ≥ goal | adds 1 to today |

* The name of a habit that is done is highlighted. A streak of two or more is shown after the progress.
* A `weekdays` habit is hidden on days it is not due. A skipped habit shows a dash and is left out of the header's count, and so is a target over more than a week, which would otherwise hold every day back until its period was met.
* A target stays in the list until it is met, and for the rest of the day it was met on. An `interval` habit is hidden while it rests. A target's progress names the period: `this week`, `this month`, `this year`, `this quarter` for three months, `this period` for any other number of them.
* Counters keep counting past the goal. Lowering one is done in the app.
* Tapping the header or a category heading opens the app. If nothing is due, the widget says so. If the user is signed out, it shows "Sign in".

### Tap handling

A tap runs a Glance `ActionCallback`:

1. Apply the change to the cache — `value`, `period_value` and the streak move together — and redraw at once.
2. Append the operation to the outbox, with the local date at the moment of the tap and a fresh `op_id`.
3. Start a flush.

The flush is a WorkManager job that needs a network connection, so it runs at once when online and waits, then retries with backoff, when not. It sends outbox operations in order:

* 2xx: remove it.
* Any other 4xx except 401, 408 and 429: remove it (the habit is gone or the request can never succeed).
* 401: stop, mark the widget signed out, keep the outbox.
* Network error, 408, 429 or 5xx: stop and retry later.
* After a flush, `GET /today?date=<local date>`, replace the cache, then re-apply whatever is still in the outbox on top of it.

A second job refreshes every 30 minutes.

Conflicts need no resolution logic: increments are additive and deduplicated by `op_id`, and sets are last-write-wins.

### Day and period change

If the cache's date is not the local date, the widget redraws from the cache without waiting for the network, then refreshes:

* Every `value` becomes 0 and nothing is skipped.
* `period_value` becomes 0 too, except for targets while the local date is no later than `period_end`. After that the widget works out the new period itself: the same number of days on for weeks, of months for months and years.
* A streak becomes 0 if the period that just ended was due, not done and not skipped.
* Which `weekdays` habits are due is recomputed from the local weekday. An `interval` habit that was done rests from that day, and one that is resting comes due on its `due_from`.

### Quick add

The `+` in the widget's header opens a small sheet over the home screen: a name, yes/no or counter, and for a counter its daily goal and unit. "Add" creates the habit on the server and refreshes the widget; "More options" opens the app's full editor instead. It needs a connection, and says so when there is none.

### NFC tags

A tag identifies a habit; the app does the logging with its own device token. The tag holds no secret, so reading or copying it gives nothing to anyone else.

**Tag contents** (NDEF):

1. A URI record: `habitd://habit/<habit id>`.
2. An Android Application Record with the app's package name, so Android always hands the tag to this app.

**Writing**: the habit editor in the Android app has "Write NFC tag". It writes the two records to any NDEF-capable tag (NTAG213 or larger). Several tags may point to the same habit. Android reads a tag back the moment it has been written, so scans of that habit are ignored for 8 seconds around a write.

**Scanning**: Android delivers the tag to a small Kotlin activity with no UI. It:

1. Reads the habit ID and looks the habit up in the cache.
2. Queues an operation in the same outbox the widget uses: **set today to 1** for a boolean habit, **add 1** for a counter.
3. Updates the cache, redraws the widget, and confirms with a vibration and a short toast ("Drink water 4/8 glasses").
4. Starts a flush and finishes.

* It works offline, exactly like a widget tap.
* A boolean scan never unchecks, so scanning twice is harmless. For counters, a second scan of the same habit within 1 second is ignored, and the toast says it was already counted.
* If the habit is not in the cache (archived, deleted, or not yet fetched), the app refreshes once and otherwise shows "Unknown habit".
* If the user is signed out, the scan opens the sign-in screen.
* Android only reads tags while the phone is unlocked.

### Reminders

A habit can have any number of reminders, each at a local time of day and on every day or only on chosen weekdays. Each gets its own alarm, set for its next occurrence. When one goes off, the app refreshes from the server (briefly; the cache is used if that fails) and shows a notification only if the habit is due today, not done and not skipped. So a habit that is only due on some days is only reminded on those, whatever its reminders say, and a target is reminded until its period's goal is met. The notification opens the app and has a button — "Done" or "Add 1" — that logs the habit through the outbox like a widget tap.

* Alarms are inexact, so a reminder can be a few minutes late; exact ones would need a special permission.
* They are set again after each refresh, after each time they go off, and after a restart of the phone.
* Android 13 and later ask the user for permission to show notifications; the app asks when a reminder time is first chosen.
* Reminders are Android only. The web app can set the time but cannot notify.

## 11. Deployment

```toml
database_path = "habits.db"
bind_address  = "0.0.0.0:8080"
public_url    = "https://habits.example.com"
trust_forwarded_for = false                    # true behind a reverse proxy

[oidc]
issuer        = "https://id.example.com"       # Pocket ID base URL
client_id     = "..."                          # from the Pocket ID client
client_secret = "..."                          # omit for a public client
scopes        = ["openid", "profile", "email"]
```

* Every key can be overridden by an environment variable: `HABITD_DATABASE_PATH`, `HABITD_OIDC__CLIENT_SECRET`, and so on. No config file is needed when they are all set that way.
* `habitd` serves plain HTTP. TLS is the reverse proxy's job, and `public_url` must be `https` outside local development.
* Migrations run at startup.
* Backup: `sqlite3 habits.db ".backup backup.db"` while running, or copy the file while stopped.
* Logs go to stdout via `tracing`. Tokens, webhook secrets and authorization codes are never logged.

The `Dockerfile` builds an image with the web app embedded; it expects `flutter build web` to have run, so that the image needs no Flutter. Inside it the database is at `/data/habits.db` and the server listens on port 8080.

### Continuous integration

Two Forgejo workflows run on pushes to `main`, each only when something it depends on changed. Both run the tests first and stop if any fail.

* **Image**: analyses and tests the app, lints and tests the server, builds the web app and the image, pushes it as `latest` and by commit, recreates the running container from it, and keeps the newest 8 image versions.
* **Android**: analyses and tests the app, builds the signed APK (for 64-bit ARM only, which keeps it near 19 MB instead of three times that), runs the Kotlin tests, and publishes the APK as release `v1.0.<run number>`, keeping the newest 10. The version code rises with the run number, so each release installs over the last.

## 12. Testing

* Server: integration tests drive the Axum router against an in-memory SQLite database. They cover completion for every schedule and kind combination, week boundaries for each `week_start`, targets over months, years and blocks of them, intervals, increment idempotency, clamping, streaks, skipped days and notes, categories, ownership checks (404 for other users' IDs), token expiry and revocation, replacing credentials on re-login, the `Origin` check, and webhook behaviour per kind.
* OIDC: tested against a mock issuer serving discovery, JWKS and the token endpoint.
* Streaks: unit tests of the counting rules.
* App: unit tests of the statistics and of period boundaries, and a widget test that taps through the habit editor's schedule options at phone width.
* Widget: Kotlin unit tests for the cache and outbox logic (optimistic apply, flush outcomes, day and period change, resting intervals, streaks, due-day filtering, categories, re-apply after refresh), NFC scans (boolean set, counter debounce, a tag just written, unknown habit) and reminder timing.

## 13. Later

* Folding a category, and logging an amount or a note, from the widget.
* Each habit's own ink in the widget.
* Exact-time reminders; reminders on the web.
* iOS app and widget.
* Monthly and interval schedules.
* Import and export.
* Restricting who may sign in from `habitd` itself.
* HMAC-signed webhooks.
