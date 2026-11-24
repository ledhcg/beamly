# Contributing to Beamly

Thanks for helping! This guide covers setup, the checks your change must pass, and how pull requests are reviewed.
By participating you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to contribute

- **Report a bug** with the bug report form. Include your macOS version, TV model and Android version, and logs
  (see [Debugging](#debugging)).
- **Suggest a feature** with the feature request form. Explain the problem before the solution.
- **Improve documentation or translations.** English is the source language; translations live in
  `macos/App/Resources/<lang>.lproj/Localizable.strings` and `android/app/src/main/res/values-<lang>/strings.xml`.
- **Send code.** For anything larger than a small fix, open an issue first so we can agree on the approach.

Security issues must **not** be reported publicly; see [SECURITY.md](SECURITY.md).

## Development setup

| Tool | Version |
|------|---------|
| macOS | 14.2 or later |
| Xcode | 16 or later (provides Swift 6, swift-format and Swift Testing) |
| JDK | 17 (Gradle 8.14 / AGP 8.7 do not run on JDK 25) |
| Android SDK | Platform 35, build-tools 35 |
| A TV or Android TV device | For end-to-end testing; enable *Network debugging* in developer options |

```sh
brew install openjdk@17          # if you do not have JDK 17
./build.sh                       # runs all tests and builds everything into build/
```

### macOS

```sh
cd macos
swift build                      # debug build
swift test                       # unit tests (Swift Testing)
swift format lint --strict --recursive Sources Tests
swift format --in-place --recursive Sources Tests   # fix formatting
Scripts/bundle-app.sh ../build   # release build + Beamly.app + beamly CLI, signed
```

Sign with a stable identity (an *Apple Development* certificate is enough for local work). macOS ties the Screen
Recording and System Audio Recording permissions to the signature; ad-hoc builds lose them on every rebuild.

### Android TV

```sh
cd android
export JAVA_HOME=$(/usr/libexec/java_home -v 17)   # or the Homebrew openjdk@17 path
./gradlew spotlessApply          # format Kotlin
./gradlew spotlessCheck check    # formatting, unit tests, Android Lint
./gradlew installDebug           # install on the connected TV
```

### End-to-end test

```sh
adb connect <tv-address>:5555
adb install -r build/beamly-tv.apk
adb shell am start -n com.mac2tv.receiver/app.beamly.tv.MainActivity
build/beamly                     # Ctrl+C to stop; the TV must return to its waiting screen
adb logcat -s StreamServer StreamSession VideoDecoder AudioPlayer NsdAdvertiser
adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png
```

## Debugging

- **Mac app:** `open -a Beamly --args --debug` writes a log to `~/Library/Logs/Beamly.log`.
  `--connect "<TV name>"` starts streaming to that TV as soon as it is found.
- **CLI:** prints connection events and throughput every 5 seconds.
- **TV:** `adb logcat -s StreamServer StreamSession VideoDecoder AudioPlayer NsdAdvertiser`.

## Coding guidelines

The complete rules (architecture invariants, threading, media pitfalls) are in [AGENTS.md](AGENTS.md); they apply to
humans too. In short:

- English for code, comments, logs, commits and documentation; user-facing text goes through localization files.
- Swift: `swift format` style, no force unwraps, no `exit()` outside the CLI, never `sync` into another component's queue.
- Kotlin: ktlint (Android Studio style), no `!!`, state hoisted into `ReceiverViewModel`, D-pad navigable UI.
- Protocol changes follow [docs/PROTOCOL.md §7](docs/PROTOCOL.md#7-changing-the-protocol) and update both sides.

## Commits and pull requests

- Branch from `main`: `feat/…`, `fix/…`, `docs/…`, `refactor/…`, `chore/…`.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):
  `feat(tv): show volume indicator`, `fix(mac): release audio tap on error`.
  Scopes: `mac`, `cli`, `app`, `tv`, `protocol`, `build`, `ci`, `docs`.
- Keep pull requests focused. Fill in the template: what changed, why, and how you tested it (device, OS version).
- Add an entry under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for user-visible changes.
- CI must pass. A maintainer reviews every pull request; we squash-merge.

## Licensing

By contributing you agree that your contributions are licensed under the [Apache License 2.0](LICENSE), the same
license as the project (see section 5 of the license).
