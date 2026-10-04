# Progress

Tracks the implementation of `SPEC.md`, milestone by milestone (spec section 12).
Update it whenever a milestone moves.

## Working on the project

Everything runs inside the Nix dev shell (`nix develop`), which provides Rust,
Flutter, JDK 17 and the Android SDK.

| Task | Command |
| --- | --- |
| Server tests | `cd server && cargo test` |
| Server lints | `cd server && cargo clippy --all-targets && cargo fmt --check` |
| Server without the web app | `cd server && cargo build --no-default-features` |
| Web app | `cd app && flutter build web --release` (then build the server to embed it) |
| App analysis | `cd app && flutter analyze` |
| Android APK | `cd app && flutter build apk --debug` |
| Kotlin unit tests | `cd app/android && ./gradlew :app:testDebugUnitTest` |

The server embeds `app/build/web` at compile time, so build the web app first
for a release binary. Without it the server still compiles and serves only the API.

## Milestones

| # | Milestone | State |
| --- | --- | --- |
| 1 | Server foundation | Done |
| 2 | Habits and entries | Done |
| 3 | Web app | Done (see notes) |
| 4 | Android app | Not started |
| 5 | Android widget | Not started |
| 6 | NFC | Not started |

### 1–2. Server (`server/`)

Config, migrations, OIDC web and app login, sessions and tokens, `/meta`, `/me`,
habits CRUD and ordering, completion logic, `/today`, `/entries`, increment and
set, webhooks, rate limits, hourly cleanup. Integration tests in `server/tests/`
run against in-memory SQLite and a mock OIDC issuer.

### 3. Web app (`app/lib/`, `server/src/web.rs`)

All screens of spec section 8: Today, habit editor, Manage, History, Settings.
The server serves the embedded build for every path the API does not claim and
redirects page visits without a session to `/auth/login`.

Notes:

* Checked by `flutter analyze`, a release web build, and API calls against a
  locally running server. The screens have not been clicked through in a
  browser against a real OIDC provider yet.

## Decisions not in the spec

* Android application ID and Kotlin package: `uk.pixxula.habytes`; the app is
  called HaBytes.
* `config.toml` has an extra `trust_forwarded_for` key so the login rate limit
  works per client behind a reverse proxy.
* Besides the four method-channel methods in the spec, Dart also asks Kotlin
  for the device's time zone and name (`getTimeZone`, `getDeviceName`).
* A new account's time zone is set from the device on first sign-in only while
  it has no habits.
