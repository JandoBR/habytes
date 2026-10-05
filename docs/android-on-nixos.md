# Building Android apps on NixOS

What it took to make a Flutter app with native Android code build on this
machine and on the Forgejo runner, written so it can be reused for another
app. Each section says what the problem was, because the fixes only make sense
with it.

The short version: NixOS has no `/usr`, the Nix store is read-only, and the
Android tooling assumes neither. Everything below follows from that.

For signing, see `android-signing.md`.

## 1. The development shell

`flake.nix` provides the whole toolchain, so nothing is installed globally and
nothing is downloaded by the tools themselves.

```nix
pkgs = import nixpkgs {
  inherit system;
  config = {
    allowUnfree = true;                    # the Android SDK is unfree
    android_sdk.accept_license = true;     # and has a licence to accept
  };
};

androidComposition = pkgs.androidenv.composeAndroidPackages {
  buildToolsVersions = [ "34.0.0" "35.0.0" "36.0.0" ];
  platformVersions = [ "34" "35" "36" ];
  abiVersions = [ "x86_64" "arm64-v8a" ];
  includeNDK = true;
  cmakeVersions = [ "3.22.1" ];            # see section 3
  includeSystemImages = false;             # no emulator: a real phone is used
  includeEmulator = false;
  useGoogleAPIs = false;
};
```

The shell needs `pkgs.flutter`, `pkgs.jdk17` and that SDK, and a `shellHook`
that tells the tools where they are:

```sh
export ANDROID_HOME="${androidSdk}/libexec/android-sdk"
export ANDROID_SDK_ROOT="${androidSdk}/libexec/android-sdk"
export JAVA_HOME="${pkgs.jdk17}"
flutter config --android-sdk "$ANDROID_HOME" > /dev/null 2>&1
```

Everything is run inside it: `nix develop`, or `nix develop --command <cmd>`.

Which versions to list is decided by the build, not by taste: when Gradle
complains that a build-tools, platform or CMake version is missing, add that
exact version here. It cannot be fetched any other way (section 2).

## 2. Gradle must not download SDK parts

**Problem.** When a component is missing, the Android Gradle Plugin tries to
download it into the SDK directory. Here that is the read-only Nix store, so it
fails with a confusing permission error instead of saying what is missing.

**Fix**, in `android/gradle.properties`:

```properties
android.builder.sdkDownload=false
```

Now a missing component is reported by name, and the answer is to add it to
the flake.

## 3. The NDK and CMake versions

**Problem.** Flutter has a preferred NDK version, and every plugin that builds
native code asks for it (`ndkVersion = flutter.ndkVersion` in the plugin's own
build file). Nix ships one NDK, usually a different version:

```
A problem occurred configuring project ':jni'.
> NDK not configured. Preferred NDK version is '28.2.13676358'.
```

Setting the version in the app's own `build.gradle.kts` is not enough: the
error comes from a plugin's module, which has its own setting. An app with no
native plugins never sees this, which is why it can appear out of nowhere when
a dependency is added.

**Fix**, in the root `android/build.gradle.kts`, before the
`evaluationDependsOn(":app")` block: use whichever NDK the shell provides, in
every module.

```kotlin
val nixNdkVersion: String? =
    System.getenv("ANDROID_HOME")
        ?.let { file("$it/ndk").listFiles()?.firstOrNull { ndk -> ndk.isDirectory }?.name }
if (nixNdkVersion != null) {
    subprojects {
        afterEvaluate {
            extensions.findByName("android")?.let { android ->
                android.javaClass
                    .getMethod("setNdkVersion", String::class.java)
                    .invoke(android, nixNdkVersion)
            }
        }
    }
}
```

It does nothing outside Nix (`ANDROID_HOME/ndk` is laid out differently
there), so the project still builds elsewhere.

**Then CMake.** With the NDK settled, the same native plugins ask for a
specific CMake:

```
[CXX1300] CMake '3.22.1' was not found in SDK, PATH, or by cmake.dir property.
```

That is `cmakeVersions = [ "3.22.1" ]` in the flake. The version in the error
is the one to list.

## 4. Running Gradle directly

`flutter build apk` works as it is. Calling `./gradlew` yourself (to run unit
tests, say) fails at once with an error that explains nothing:

```
The settings are not yet available for build.
```

**Problem.** Two things `flutter build` quietly takes care of on NixOS:

* The Flutter Gradle plugin is included from the Nix store, and Gradle wants
  to write its project cache next to it. The store is read-only.
* Gradle downloads its own `aapt2`, a prebuilt binary that cannot run on NixOS
  (no standard dynamic linker).

**Fix**: `app/android/nix-gradlew`, a wrapper that passes what Flutter passes.

```sh
cache="${XDG_CACHE_HOME:-$HOME/.cache}/habytes-gradle"
aapt2="$(ls -d "$ANDROID_HOME"/build-tools/*/aapt2 | sort -V | tail -n 1)"

exec ./gradlew \
  --project-cache-dir="$cache/project" \
  -Pkotlin.project.persistent.dir="$cache/kotlin" \
  -Pandroid.aapt2FromMavenOverride="$aapt2" \
  "$@"
```

```sh
cd app/android && ./nix-gradlew :app:testDebugUnitTest
```

To see what Flutter itself runs, `flutter build apk -v` prints the full Gradle
command.

## 5. Memory

Gradle keeps a daemon alive between builds, and the Kotlin compiler keeps
another. Flutter's template allows the Gradle one 8 GB, and it will use most
of that and hold it for hours. On a 16 GB machine that is half the memory, for
a process doing nothing.

* `android/gradle.properties` caps it: `org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=2G ...`
* `./gradlew --stop` (in `app/android`) ends the daemons when you are done.

## 6. Kotlin with Compose (for a Glance widget)

A Glance widget is written with the Compose compiler, which since Kotlin 2 is
a Gradle plugin whose version must equal the Kotlin version. In
`android/settings.gradle.kts`:

```kotlin
id("org.jetbrains.kotlin.android") version "2.4.0" apply false
id("org.jetbrains.kotlin.plugin.compose") version "2.4.0" apply false
```

and in `android/app/build.gradle.kts`, `id("org.jetbrains.kotlin.plugin.compose")`
in the `plugins` block, after the Flutter plugin.

Pure-Kotlin logic kept free of Android classes can be unit-tested on the JVM
(`src/test/kotlin`). `org.json` is the exception: the SDK only has a stub of
it for tests, so add the real one:

```kotlin
testImplementation("junit:junit:4.13.2")
testImplementation("org.json:json:20240303")
```

## 7. Release builds are not debug builds

Three things that only show up in a release build:

* **Code shrinking.** R8 removes what looks unused, including classes that are
  only ever created by reflection. The app then crashes at start, in a library:

  ```
  NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []
  ```

  The cure is a keep rule in `android/app/proguard-rules.pro`, which Flutter
  picks up by itself. This project needs them for WorkManager's database, its
  workers, and Glance's tap actions. Read the crash with
  `adb logcat -b crash`.
* **Plain HTTP is refused.** A release build only talks HTTPS. For testing
  against a server on the development machine, the *debug* manifest
  (`src/debug/AndroidManifest.xml`) allows it:
  `<application android:usesCleartextTraffic="true"/>`.
* **Signing.** A release build signed with the debug key cannot be updated by
  one signed with the real key, or the other way round. See `android-signing.md`.

Always start a release build on a phone once before trusting it.

## 8. Flutter and native launch intents

A Glance widget's `actionStartActivity` adds a data URI to its intent to keep
intents distinct. Flutter takes any intent data for a deep link and hands it
to the router, which shows "page not found". Unless the app really is opened
through links, switch that off on the Flutter activity:

```xml
<meta-data android:name="flutter_deeplinking_enabled" android:value="false" />
```

To open a particular screen from native code, pass it as an intent extra and
let Dart ask for it over a method channel (`takeLaunchRoute` here).

## 9. A real phone

No emulator is set up; the phone is the test device.

* **Getting it seen.** `adb devices` must list it. If it is not even in
  `lsusb`, it is the cable (charge-only) or the USB mode: choose *File
  transfer* in the phone's USB notification. Then accept "Allow USB debugging".
* **Xiaomi (MIUI).** Installing over USB needs *Install via USB* enabled in
  Developer options, and the phone shows a prompt for each install;
  `INSTALL_FAILED_USER_RESTRICTED` means it was not accepted. MIUI also
  restricts background work for new apps: set the app to *No restrictions*
  under battery saver if sync or alarms seem late.
* **Installing.** `adb install -r app.apk` keeps the app's data.
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE` means the installed one has another
  signature: `adb uninstall <package>` first.
* **Reaching a server on this machine.** `adb reverse tcp:8787 tcp:8787` makes
  the phone's `localhost:8787` this machine's, over the cable. It lasts until
  the cable is unplugged, which is also a handy way to test offline behaviour.
* **Looking at it.** `adb exec-out screencap -p > shot.png` for a screenshot,
  `adb shell input tap X Y` to tap, `adb logcat -b crash` for crashes, and
  `adb shell run-as <package> cat shared_prefs/<file>.xml` to read a debug
  build's stored state.

## 10. Building on the Forgejo runner

The runner executes jobs in an Ubuntu container that has the host's Docker
socket and a Nix store mounted at `/nix`.

* **Nix is installed but not on `PATH`**, and the container has no `nixbld`
  group or sandbox. Every step that uses it starts with:

  ```yaml
  env:
    NIX_CONFIG: |
      build-users-group =
      sandbox = false
      experimental-features = nix-command flakes
  ```
  ```sh
  export PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH"
  nix develop --command bash -c '...'
  ```

  The build then uses exactly the toolchain of the flake, the same as locally.
* **Smaller shells for smaller jobs.** The default shell pulls the whole
  Android SDK. Jobs that do not need it use `nix develop .#web` (Flutter only)
  or `.#server` (Rust only), defined at the end of `flake.nix`.
* **The first Android build is slow** (about twenty minutes): the SDK lands in
  the runner's Nix store and Gradle fetches its dependencies. Nothing caches
  Gradle between runs, so later ones are faster but not fast.
* **Docker Hub rate-limits the server.** Pulling `rust:1-slim` failed a build
  with `429 Too Many Requests`. Official images are mirrored without that limit
  at `public.ecr.aws/docker/library/<image>`; the `Dockerfile` and
  `scripts/deploy` use that.
* **A newer push cancels an older run of the same workflow.** A run that
  disappears was superseded, not broken.
* **Version numbers.** Android refuses an update whose version code is not
  higher than the installed one's. CI passes the run number:
  `flutter build apk --release --build-name "1.0.$N" --build-number "$N"`.
* **Signing in CI** comes from repository secrets; **publishing** uses the
  token each run gets for its own repository, so releases need no setup
  (`scripts/publish-release`).

## Checklist for a new app

1. Copy `flake.nix` and trim it to what the app needs.
2. `android/gradle.properties`: `android.builder.sdkDownload=false`, and lower
   `-Xmx`.
3. `android/build.gradle.kts`: the NDK override.
4. Build; add to the flake whatever SDK component the error names.
5. Copy `android/nix-gradlew` if Gradle will be called directly.
6. Set up signing before the first release build is installed anywhere
   (`android-signing.md`).
7. Run a release build on a phone and read `adb logcat -b crash`.
8. For CI, copy `.forgejo/workflows/android.yml` and `scripts/publish-release`.
