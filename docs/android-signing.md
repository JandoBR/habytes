# Android signing

How the HaBytes app is signed, and how to set the same thing up for another
Android app.

## What it is

Android only installs an APK over an existing app if both were signed with the
same key. That is how it knows an update comes from whoever made the original,
and it is why updates keep the app's data: a different signature is treated as
a different author, and the only way forward is to uninstall first.

The key lives in a **keystore**: one password-protected file. Inside it, a key
has a name, its **alias**. So signing an app takes four things:

| | For HaBytes |
| --- | --- |
| The keystore file | `~/.config/habytes/release.jks` |
| The keystore's password | in `~/.config/habytes/keystore.env` |
| The key's alias | `habytes` |
| The key's password | the same as the keystore's (the PKCS12 format has only one) |

There is no account, service or registry behind it: the file is the whole
thing. Nobody can reissue it. **If it is lost, the app can never be updated
again**, only replaced by a new install; if it leaks, someone else can ship
"updates" to it. So it is kept out of the repository and backed up.

A **debug** build is signed with a throwaway key that Android's tools generate
on each machine. It is fine for trying things, but a debug build and a release
build cannot replace one another.

## Where the HaBytes key is

| Place | What is there | Used by |
| --- | --- | --- |
| `~/.config/habytes/release.jks` and `keystore.env` | The keystore and its password | Local release builds |
| Repository secrets on Forgejo: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | The same, with the file encoded as text | The Android workflow |
| `shared/secrets.yaml` in `nixos-config`: `HABYTES_KEYSTORE_BASE64`, `HABYTES_KEYSTORE_PASSWORD` | A backup, encrypted with sops | Recovery |

To get the keystore back from the backup:

```sh
cd ~/.nixos-config
sops -d --extract '["HABYTES_KEYSTORE_BASE64"]' shared/secrets.yaml | base64 -d > release.jks
sops -d --extract '["HABYTES_KEYSTORE_PASSWORD"]' shared/secrets.yaml
```

## How a build picks it up

`app/android/app/build.gradle.kts` reads four environment variables. When
`ANDROID_KEYSTORE_FILE` is set, release builds are signed with that keystore;
when it is not, they fall back to the debug key.

```kotlin
val keystoreFile = System.getenv("ANDROID_KEYSTORE_FILE")
signingConfigs {
    if (!keystoreFile.isNullOrEmpty()) {
        create("release") {
            storeFile = file(keystoreFile)
            storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("ANDROID_KEY_ALIAS")
            keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
        }
    }
}
buildTypes {
    release {
        signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
    }
}
```

* **Locally**, the dev shell (`flake.nix`) sources `~/.config/habytes/keystore.env`,
  which exports those four variables. So inside `nix develop`,
  `flutter build apk --release` is signed with the real key with nothing else to do.
* **In CI**, the workflow decodes `ANDROID_KEYSTORE_BASE64` into a temporary
  file and sets the variables from the secrets (`.forgejo/workflows/android.yml`).

To see which key an APK was signed with:

```sh
$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs app-release.apk
```

A release build shows `CN=HaBytes`; a debug build shows `CN=Android Debug`.

## Doing it for another app

Use a separate key per app, so that losing or leaking one affects only that app.

1. **Make the keystore.** Pick a name for the app in place of `myapp`:

   ```sh
   mkdir -p ~/.config/myapp && chmod 700 ~/.config/myapp
   PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 28)"
   keytool -genkeypair -storetype PKCS12 \
     -keystore ~/.config/myapp/release.jks -alias myapp \
     -keyalg RSA -keysize 4096 -validity 10000 \
     -storepass "$PASSWORD" -keypass "$PASSWORD" -dname "CN=MyApp"
   chmod 600 ~/.config/myapp/release.jks
   ```

   `keytool` comes with the JDK, so it is available inside the dev shell.
   `-validity 10000` is about 27 years; the key should outlive the app.

2. **Write down the password where builds can find it:**

   ```sh
   cat > ~/.config/myapp/keystore.env <<EOF
   export ANDROID_KEYSTORE_FILE="$HOME/.config/myapp/release.jks"
   export ANDROID_KEYSTORE_PASSWORD="$PASSWORD"
   export ANDROID_KEY_ALIAS="myapp"
   export ANDROID_KEY_PASSWORD="$PASSWORD"
   EOF
   chmod 600 ~/.config/myapp/keystore.env
   ```

3. **Back it up** before anything is installed with it:

   ```sh
   cd ~/.nixos-config
   sops set shared/secrets.yaml '["MYAPP_KEYSTORE_PASSWORD"]' "\"$PASSWORD\""
   sops set shared/secrets.yaml '["MYAPP_KEYSTORE_BASE64"]' "\"$(base64 -w0 ~/.config/myapp/release.jks)\""
   ```

4. **Teach the app's build to use it**: copy the Gradle block above into its
   `android/app/build.gradle.kts`, and have its dev shell source the env file
   (the last lines of the `shellHook` in this repository's `flake.nix`).

5. **For CI**, add four repository secrets. The keystore goes in as text:

   ```sh
   base64 -w0 ~/.config/myapp/release.jks | wl-copy   # paste as ANDROID_KEYSTORE_BASE64
   ```

   The other three are the password (twice) and the alias. The "Set up
   signing" step of `.forgejo/workflows/android.yml` shows how a workflow turns
   them back into a file.

6. **Give every build a higher version code than the last.** Android refuses
   an "update" whose version code is not greater than the installed one's.
   Here CI passes the run number: `--build-number`.

## Things that go wrong

* **"App not installed" or `INSTALL_FAILED_UPDATE_INCOMPATIBLE`**: the
  installed app was signed with a different key (a debug build, usually).
  Uninstall it once, then install the release.
* **A release build that crashes at start although the debug build works**:
  release builds strip code that looks unused. Classes only reached by
  reflection need a keep rule; see `app/android/app/proguard-rules.pro`.
* **The key cannot be changed for an installed app.** A new key means a new
  install for everyone who has it.
