# Progress

What `SPEC.md` does not say: how far along things are, what has actually been
tried, where things live, and why some of it is the way it is.

## State

Everything in `SPEC.md` is built, deployed at `https://habits.example.com`, and
covered by tests that run in CI before anything is deployed.

### Tried on a real phone

A POCO X3 GT (Android 13, MIUI, Firefox as the browser).

| | |
| --- | --- |
| Sign-in, including the browser tab closing by itself | Works |
| Today, with a device token | Works |
| Widget: tapping yes/no habits and counters | Works |
| Widget: taps made offline, delivered after reconnecting | Works |
| Widget: the current look, the header opening the app, the `+` sheet opening | Works |
| NFC: writing a tag and scanning it | Works |
| The signed release build installing and starting | Works |
| Widget: category headings, skipped marks | Not tried |
| Quick add: actually adding a habit | Not tried |
| Reminders: the permission prompt, the notification, its button | Not tried |
| Widget: rolling over at midnight and at the start of a week | Not tried |
| A revoked device token (the widget should say "Sign in" and keep its queue) | Not tried |

MIUI restricts background work for new apps. If reminders or background sync
seem late, set the app to "No restrictions" under battery saver.

### Tried in a browser

The web app has only been looked at through headless screenshots at phone
width, against a local server with sample data, plus one real sign-in on the
deployed one. Not looked at: wide desktop windows, and whether a keyboard
link-hint extension now reaches every control.

## Where things are

### Server (`server/src/`)

| File | What it is |
| --- | --- |
| `auth.rs`, `oidc.rs`, `extract.rs` | Login flows, the relying party, and how a request is authenticated. |
| `api/habits.rs`, `api/categories.rs`, `api/entries.rs`, `api/tokens.rs`, `api/me.rs` | The JSON API. |
| `schedule.rs`, `streak.rs` | Due days, week boundaries, completion; streak counting. |
| `hooks.rs`, `ratelimit.rs` | Webhooks and the in-memory limits. |
| `web.rs` | Serves the embedded web app and sends page visits without a session to the login. |

### App (`app/lib/`)

| File | What it is |
| --- | --- |
| `theme.dart` | The whole look: palettes, fonts, component styles, the habit inks. |
| `widgets/common.dart` | Shared pieces: `Stamp`, `Highlighted`, `Meter`, `WeekStrip`, `Logo`. |
| `screens/` | One file per screen. |
| `state/` | Riverpod providers: sign-in state, Today, habits, categories. |
| `stats.dart` | The History screen's figures. |
| `platform/` | What differs by platform: the native channel, NFC writing, the browser. |

### Android (`app/android/app/src/main/kotlin/uk/pixxula/habytes/`)

| File | What it is |
| --- | --- |
| `Model.kt` | Cache, habits, categories and outbox operations: optimistic apply, day and week change, streaks, due-day filtering. Pure Kotlin. |
| `HabitSync.kt` | Taps, NFC scans, and the flush + refresh exchange with the server. Pure Kotlin behind `StateStore` and `Api`. |
| `Json.kt`, `Store.kt`, `HttpApi.kt` | Serialisation, the SharedPreferences store, the `HttpURLConnection` client. |
| `Widgets.kt` | Process-wide glue: the shared `HabitSync`, redraws, WorkManager jobs. |
| `HabitWidget.kt` | The Glance widget, its tap action and its receiver. |
| `QuickAddActivity.kt` | The widget's `+` sheet. |
| `NfcScanActivity.kt` | UI-less activity for `habitd://habit/<id>` tags. |
| `Reminders.kt` | Alarms, the notification and its button, rescheduling after a restart. |
| `AuthCallbackActivity.kt` | Receives the sign-in redirect. |
| `MainActivity.kt` | The `habitd/native` method channel. |

## Working on it

`README.md` has the everyday commands. The whole account of building for
Android on NixOS, the runner, deploying and signing is in the Dev-kit
repository (`forgejo.example.com/Jando/Dev-kit`), which also has the generic
form of this project's workflows and scripts. In short:

* Use `app/android/nix-gradlew` instead of `./gradlew` when calling Gradle
  directly; it passes the options `flutter build` passes on NixOS.
* The server embeds `app/build/web` at compile time. Without it the server
  still compiles and serves only the API; debug builds read the files from disk
  at run time, so rebuilding the web app is enough.
* Gradle's daemon holds several gigabytes while idle. `./gradlew --stop` in
  `app/android` frees them.
* `scripts/make-icons` redraws every icon from the logo's geometry.

## Build and deployment

* The workflows are described in `SPEC.md` section 11. They need the
  repository secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
  `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`; without them the APK is
  signed with a throwaway debug key and cannot update an installed one.
* The release signing key is `~/.config/habytes/release.jks` on the dev
  machine (alias `habytes`), with its password in `keystore.env` next to it.
  The dev shell sources that file, so a local `flutter build apk --release`
  uses the same key as CI. A backup of both is in `shared/secrets.yaml` of
  `nixos-config` (`HABYTES_KEYSTORE_*`). Losing the key means installed apps
  can no longer be updated, only reinstalled. To restore it:
  `sops -d --extract '["HABYTES_KEYSTORE_BASE64"]' shared/secrets.yaml | base64 -d > release.jks`.
* The server side is the `habitd` stack in `~/.nixos-config/server/stacks/`,
  served through SWAG, data in `/srv/appdata/habitd`. The CI runner has the
  host's Docker socket, which is what lets the workflow deploy and prune;
  pruning also relies on the registry stack allowing deletes
  (`REGISTRY_STORAGE_DELETE_ENABLED`).
* `scripts/publish-image` does what the image workflow does, from a dev machine.

## Why it is this way

* **A widget tap queues, it does not send.** A tap handler only gets a few
  seconds to run, which a slow request could exceed. The flush is a
  WorkManager job that runs at once when online.
* **Flushing drops any 4xx but 401, 408 and 429.** Anything else that can
  never succeed would block the queue forever.
* **An unsent "set" from an earlier day is not counted towards a weekly
  total** when the cache is rebuilt: the amount depends on a value only the
  server has. Unsent increments are counted. The next refresh corrects it.
* **Folding is stored on the server**, so the web app, the phone and the
  widget agree, and the widget needs no fold action of its own.
* **Signing in again replaces the old credential.** Reinstalling the app used
  to leave a device token behind that nothing could use and that never expired.
* **A habit's webhook is in its editor**, not in Settings, which would
  otherwise list every habit.
* **Our own `AuthCallbackActivity`** instead of the one from
  `flutter_web_auth_2`, which left the browser tab open when the browser
  delivers the redirect in its own task, as Firefox does.
* **Flutter deep linking is off on Android.** The widget's launch intents
  carry a data URI that Flutter read as a route, landing on "page not found".
* **Release builds keep a few classes** (`app/android/app/proguard-rules.pro`)
  that are only created by reflection; without them the app crashed at start.
* **Reminders use inexact alarms**, which need no special permission.
* **Base images come from `public.ecr.aws`**, not Docker Hub, whose pull limit
  failed a CI build.
* **The Nix shell's NDK is used for every Gradle module**
  (`app/android/build.gradle.kts`): plugins with native code ask for Flutter's
  preferred version, which the read-only store cannot download.
* **The NFC debounce timestamp is kept in memory**, not on disk; it only
  matters for a second.
* **Debug builds allow plain HTTP** so the app can talk to a development
  server; release builds do not.
* **A new account's time zone is set from the device** only while it has no
  habits, so it never moves a day's worth of existing entries.
* The Android application ID and Kotlin package are `uk.pixxula.habytes`.
