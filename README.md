# HaBytes

A self-hosted habit tracker built around a home-screen widget.

* **`habitd`** — one Rust binary with a SQLite file. It serves the JSON API,
  per-habit webhooks and the web app.
* **Web app** — manage habits, log them, and look back: streaks, a year-long
  heatmap, completion rates.
* **Android app** — the same screens, plus the widget, NFC tags and reminders.
* **Widget** — today's habits on the home screen. One tap logs a habit, online
  or offline; a `+` adds a new one without opening the app.

Sign-in goes through your own OIDC provider (it is used with
[Pocket ID](https://pocket-id.org); any standard provider works), so there are
no passwords to manage.

## What it does

* Yes/no habits and counters, with a unit (`8 glasses`, `120 pages`).
* Schedules: every day, picked weekdays, or a weekly target.
* Streaks, in days or in weeks. A day can be skipped (ill, travelling) without
  breaking one, and can carry a note.
* Categories that fold away, a colour per habit, and each habit's week at a
  glance.
* Taps made offline are queued on the phone and delivered later, exactly once.
* NFC: write a habit to a tag in the app, then tap the phone on it to log.
* Webhooks and API tokens, for Home Assistant, buttons and scripts.

## Layout

```
server/     habitd (Rust, Axum, SQLx/SQLite)
app/        Flutter app: web and Android
  android/  the widget, NFC scans and reminders, in Kotlin
scripts/    publish-image, deploy, prune-images, make-icons
SPEC.md     what it is and how it works; PROGRESS.md: what has been verified, and why
```

## Developing

Everything runs in the Nix dev shell, which provides Rust, Flutter, a JDK and
the Android SDK:

```sh
nix develop
```

| Task | Command |
| --- | --- |
| Server tests | `cd server && cargo test` |
| App tests | `cd app && flutter test` |
| Widget tests | `cd app/android && ./nix-gradlew :app:testDebugUnitTest` |
| Web app | `cd app && flutter build web --release` |
| Android app | `cd app && flutter build apk --release` |

To run it locally, copy `server/config.example.toml` to `server/config.toml`,
point it at your OIDC provider, build the web app, and start the server:

```sh
cd app && flutter build web --release
cd ../server && cargo run -- config.toml
```

The server embeds `app/build/web`, so build the web app first. Register
`{public_url}/auth/callback` as the redirect URI at your provider.

`PROGRESS.md` has the details: how the parts fit together, the decisions made
along the way, and what has and has not been tried on a real phone.

## Running it

`habitd` needs a config file or `HABITD_*` environment variables, a writable
directory for its database, and a reverse proxy that terminates TLS:

```yaml
services:
  habitd:
    image: registry.example.com/habitd:latest
    user: "99:100"
    environment:
      - HABITD_PUBLIC_URL=https://habits.example.com
      - HABITD_TRUST_FORWARDED_FOR=true
      - HABITD_OIDC__ISSUER=https://id.example.com
      - HABITD_OIDC__CLIENT_ID=...
      - HABITD_OIDC__CLIENT_SECRET=...
    volumes:
      - ./data:/data
    ports:
      - "8080:8080"
```

`scripts/publish-image` builds and pushes the image. The Forgejo workflows in
`.forgejo/workflows/` test, build, push and deploy on every push to `main`, and
build a signed APK.

Back up by copying the database while the server is stopped, or with
`sqlite3 habits.db ".backup backup.db"` while it runs.

## Getting the Android app

Every build of the app is published on the repository's **Releases** page as
`v1.0.<n>`, with the signed APK attached (`habytes-1.0.<n>.apk`). Download the
newest one and open it to install; later releases install over it and keep
your sign-in and widget.

To be told about new releases, add the repository's address to
[Obtainium](https://github.com/ImranR98/Obtainium) on the phone (it knows
Forgejo). It then offers each new release as an update.

All releases are signed with the same key. An APK built without that key (a
debug build, say) will not install over a released one, and the other way round.

## Automating

Every action in the app is an API call (`/api/v1/*`, described in `SPEC.md`),
authenticated with a token made under Settings. For things that cannot send a
token, give a habit a webhook (in its editor) and `POST` to its URL:

```sh
curl -X POST https://habits.example.com/hook/<secret>            # log it
curl -X POST "https://habits.example.com/hook/<secret>?delta=3"  # add 3 to a counter
```
