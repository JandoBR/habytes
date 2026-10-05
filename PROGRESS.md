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
| Kotlin unit tests | `cd app/android && ./nix-gradlew :app:testDebugUnitTest` |

Use `app/android/nix-gradlew` instead of `./gradlew` when calling Gradle
directly; it passes the options `flutter build` passes on NixOS.

The server embeds `app/build/web` at compile time, so build the web app first
for a release binary. Without it the server still compiles and serves only the API.

## Milestones

| # | Milestone | State |
| --- | --- | --- |
| 1 | Server foundation | Done |
| 2 | Habits and entries | Done |
| 3 | Web app | Done (see notes) |
| 4 | Android app | Done, run on a phone (debug build) |
| 5 | Android widget | Done, run on a phone (debug build) |
| 6 | NFC | Done, run on a phone (debug build) |

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

### 4–6. Android (`app/android/app/src/main/kotlin/uk/pixxula/habytes/`)

| File | What it is |
| --- | --- |
| `Model.kt` | Cache, habits and outbox operations: optimistic apply, day and week change, due-day filtering. Pure Kotlin. |
| `HabitSync.kt` | Taps, NFC scans, and the flush + refresh exchange with the server. Pure Kotlin behind `StateStore` and `Api`. |
| `Json.kt`, `Store.kt`, `HttpApi.kt` | Serialisation, the SharedPreferences store (excluded from backups), `HttpURLConnection` client. |
| `Widgets.kt` | Process-wide glue: the shared `HabitSync`, redraws, WorkManager jobs (`SyncWorker`). |
| `HabitWidget.kt` | The Glance widget, its tap action and its receiver. |
| `NfcScanActivity.kt` | UI-less activity for `habitd://habit/<id>` tags. |
| `MainActivity.kt` | The `habitd/native` method channel. |

Dart side: `lib/platform/native.dart` (channel), `lib/platform/nfc.dart` (tag
writing, from the habit editor), `lib/screens/server.dart`, `sign_in.dart`,
`device.dart` (the spec's Home screen).

Kotlin unit tests (`app/android/app/src/test/`) cover the cache and outbox
logic and NFC scans, as listed in spec section 11.

Still to do:

* Tried on a POCO X3 GT (Android 13, Firefox as browser): sign-in, Today, the
  widget, taps made offline and delivered after reconnecting, writing and
  scanning a tag (debug build, local server over `adb reverse`). The signed
  release build installs and starts against `https://habits.example.com`; its
  widget, background sync and NFC scan have not been re-checked. Not tried at
  all yet: day and week change on the widget, a revoked token.

## Build and deployment

* Two Forgejo workflows run on pushes to `main` and by hand:
  * `image.yml`, when `server/`, `app/` (other than `app/android/`), the
    Dockerfile or the flake changed: builds the web app and habitd, pushes
    `registry.example.com/habitd:latest` and `:<commit>`, puts it live with
    `scripts/deploy` (pull and recreate the server's `habitd` stack), then
    `scripts/prune-images` keeps the newest 8 versions in the registry and on
    the server and deletes the rest.
  * `android.yml`, when `app/` or the flake changed: builds the release APK
    (artifact `habytes-apk`) and runs the
    Kotlin unit tests. It signs with the keystore in the repository secrets
    `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`
    and `ANDROID_KEY_PASSWORD`; without them it uses a throwaway debug key, and
    such an APK cannot update an installed one.
* The release signing key is `~/.config/habytes/release.jks` on the dev
  machine (alias `habytes`), with its password in `keystore.env` next to it.
  The dev shell sources that file, so local `flutter build apk --release` uses
  the same key as CI. A backup of both is in `shared/secrets.yaml` of
  `nixos-config` (`HABYTES_KEYSTORE_*`). Losing the key means installed apps
  can no longer be updated, only reinstalled.
* `scripts/publish-image` does the same as the `image` job from a dev machine.
* The server side is the `habitd` stack in `~/.nixos-config/server/stacks/`,
  served at `https://habits.example.com` through SWAG, data in
  `/srv/appdata/habitd`. The CI runner has the host's Docker socket, which is
  what lets the workflow deploy and prune; pruning also relies on the registry
  stack allowing deletes (`REGISTRY_STORAGE_DELETE_ENABLED`).

## Beyond the spec

The spec is the starting point, not the limit. Added since:

* **Streaks** (`server/src/streak.rs`): current and best, counted in due days
  or in weeks, reported by `/today` and by every write.
* **Skipped days and notes**: `PUT .../entries/{date}` takes any of `value`,
  `skipped` and `note`. A skipped day neither counts towards a streak nor
  breaks it; a week with a skipped day is excused the same way.
* **Categories** (`/categories`): named groups that remember whether they are
  folded. Today and the widget list habits under them and hide folded ones.
* **Per-habit unit, ink and reminder time** (`unit`, `color`, `reminder_time`).
* **Week strip**: `/today` returns each habit's week day by day
  (`week_values`, `week_skipped`).
* **Stats** (`app/lib/stats.dart`): completion over 30 and 90 days, best
  weekday and a twelve-week trend, worked out in the app from `/entries`.
* **Reminders** (`Reminders.kt`): Android only. One inexact alarm per habit;
  when it goes off the app refreshes, and notifies if the habit is due, not
  done and not skipped. The notification has a button that logs it.

* **Quick add** (`QuickAddActivity.kt`): the widget's `+` opens a small sheet
  over the home screen that creates a habit (name, yes/no or a daily counter)
  without opening the app. It needs a connection.
* **Logo**: an H made of bits with the crossbar in the highlighter.
  `scripts/make-icons` draws it into every web and Android icon; the adaptive
  launcher icon is `ic_launcher_foreground.xml`.

Seen working on the phone: the restyled widget, its header opening the app and
the quick-add sheet. Not tried there yet: category headings and skipped marks
in the widget, actually adding a habit from the sheet, and reminders.

The web app keeps Flutter's semantics tree on, so every control is also a real
element: for screen readers, and for keyboard link-hint extensions.

## Look

`app/lib/theme.dart` holds the whole look: flat ink on paper, hairlines
instead of shadows, and one loud colour used only as a highlighter over what is
done. Three palettes are defined there (`riso`, the default, `ledger` and
`graphite`), chosen at build time with `--dart-define=PALETTE=<name>`. Fonts
are bundled in `app/assets/fonts/` (Bricolage Grotesque, Instrument Sans, DM
Mono; all Open Font License). Shared pieces (`Stamp`, `Highlighted`, `Meter`)
are in `lib/widgets/common.dart`.

## Decisions not in the spec

* Android application ID and Kotlin package: `uk.pixxula.habytes`; the app is
  called HaBytes.
* `config.toml` has an extra `trust_forwarded_for` key so the login rate limit
  works per client behind a reverse proxy.
* Besides the four method-channel methods in the spec, Dart also asks Kotlin
  for the device's time zone and name (`getTimeZone`, `getDeviceName`).
* A new account's time zone is set from the device on first sign-in only while
  it has no habits.
* A widget tap does not send the request itself: it queues the operation and
  starts a WorkManager job that needs a network connection, which flushes right
  away when online and retries with backoff otherwise. A tap handler only gets
  a few seconds to run, which a slow request could exceed.
* During a flush, every 4xx answer other than 401, 408 and 429 drops the
  operation (the spec names 404 and 422); anything else that can never succeed
  would block the queue forever.
* An unsent "set" from an earlier day of the week is not counted towards a
  weekly total when the cache is rebuilt (the amount depends on a value only
  the server has); unsent increments are. The next refresh corrects it.
* The NFC debounce timestamp is kept in memory, not on disk.
* The sign-in redirect is received by our own `AuthCallbackActivity`, not the
  one from `flutter_web_auth_2`, which left the browser tab open with Firefox.
* Release builds keep a few classes that are only created by reflection
  (`app/android/app/proguard-rules.pro`); without them the app crashed at start.
* Base images come from `public.ecr.aws` rather than Docker Hub, whose pull
  limit failed a CI build.
* Debug builds allow plain HTTP so the app can talk to a development server.
* The Nix shell's NDK is used for every Gradle module (`app/android/build.gradle.kts`).
