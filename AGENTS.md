# AGENTS.md

Instructions for AI coding agents working in this repository. Humans should start with `README.md`
and `CONTRIBUTING.md`; this file holds the operational rules agents need to make correct changes.

Keep this file accurate: when a rule here no longer matches the code, fix the file in the same change.

---

## 1. Project overview

The project mirrors a Mac's screen and system audio to an Android TV on the same local network.

| Component | Path | Language / stack |
|-----------|------|------------------|
| Streaming engine (capture, encode, audio tap, network, discovery) | `mac/Engine.swift` | Swift 5 mode, ScreenCaptureKit, VideoToolbox, Core Audio, Network.framework |
| Menu bar app | `mac/app/` | AppKit (`NSStatusItem`), ServiceManagement |
| Command-line sender | `mac/cli/` | Swift |
| TV receiver | `android/app/` | Kotlin, Jetpack Compose for TV, coroutines, MediaCodec, AudioTrack, NsdManager |

Data flow: ScreenCaptureKit frame → VideoToolbox H.264 (Annex-B) → TCP → `StreamServer` →
`StreamSession` → `VideoDecoder` (MediaCodec → `SurfaceView`). Audio: Core Audio process tap (or
ScreenCaptureKit audio) → PCM s16le 48 kHz stereo → TCP → `AudioPlayer` (AudioTrack).
Discovery: the TV advertises `_mac2tv._tcp` over mDNS; the Mac browses with `NWBrowser`.

---

## 2. Commands

Run from the repository root unless noted.

| Task | Command |
|------|---------|
| Build everything (CLI, `.app`, APK) and run Android unit tests | `./build.sh` |
| Android unit tests only | `cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew testReleaseUnitTest` |
| Android lint | `cd android && JAVA_HOME=… ./gradlew lintRelease` (report: `android/app/build/reports/lint-results-release.html`) |
| Type-check Swift quickly | `swiftc -swift-version 5 -typecheck mac/Engine.swift mac/cli/main.swift` |
| Install on a TV | `adb connect <tv-ip>:5555 && adb install -r build/mac2tv-receiver.apk` |
| Launch on the TV | `adb shell am start -S -n com.mac2tv.receiver/.MainActivity` |
| Stream from the CLI | `build/mac2tv` (auto-discovers the TV) or `build/mac2tv <tv-ip>` |
| TV logs | `adb logcat -s StreamServer StreamSession VideoDecoder AudioPlayer NsdAdvertiser` |
| Screenshot the TV | `adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png` |

Toolchain notes:
- Gradle 8.14 / AGP 8.7 need **JDK 17–24**. The JBR bundled with Android Studio may be newer and fails with an error that only prints the Java version. Use JDK 17.
- The macOS app must be code-signed with a stable identity (`build.sh` picks the first "Apple Development" identity) or macOS forgets the Screen Recording / System Audio Recording permissions after every rebuild.

---

## 3. Definition of done

A change is complete only when all of these hold:

1. `./build.sh` succeeds with no new compiler warnings.
2. Android unit tests pass; `lintRelease` reports no errors.
3. Behaviour that touches streaming was exercised end to end: TV app open, `build/mac2tv` connected, picture visible (verify with an `adb` screenshot), clean stop with Ctrl+C returns the TV to the waiting screen.
4. Protocol changes are reflected on **both** sides, in `docs/PROTOCOL.md` (once it exists) and in tests.
5. `AGENTS.md`, `README.md` and `CHANGELOG.md` are updated when commands, behaviour or user-visible features change.
6. Any system state you changed while testing (macOS output volume/mute, TV app state) is restored.

Report honestly: if a step could not be run (no TV reachable, missing permission), say so explicitly
instead of implying it passed.

---

## 4. Language and text

- **English only** for code, identifiers, comments, log messages, commit messages, PR text and documentation.
- User-facing text is localised. English is the source language; Vietnamese is a translation.
  - Android: `res/values/strings.xml` (English) and `res/values-vi/strings.xml`. Never hard-code UI text in Kotlin.
  - macOS: move strings into a String Catalog when touching them; do not add new hard-coded UI strings.
- Do not use Apple trademarks ("Mac", "macOS", Apple logos) in new product names, icons or app titles. Refer to compatibility in prose only ("for macOS").

---

## 5. Wire protocol rules

Packet framing (big-endian): `u32 length | u8 type | u64 ptsMicros | payload[length]`.

| Type | Name | Payload |
|------|------|---------|
| 0 | CONFIG | `u16 width, u16 height, u16 spsLen, sps, u16 ppsLen, pps` |
| 1 | KEY_FRAME | H.264 access unit, Annex-B |
| 2 | FRAME | H.264 access unit, Annex-B |
| 3 | AUDIO | PCM s16le, 48 kHz, stereo, interleaved |
| 4 | BYE | empty — sender stopped on purpose |
| 5 | PING | empty — heartbeat every second |
| 6 | HELLO | UTF-8 device name, sent first on every connection |
| 7 | VOLUME | `f32 volume, f32 gain, u8 muted` |

Rules:
- Definitions live in `mac/Engine.swift` (header comment + `Sender`) and `android/.../net/Protocol.kt`. Change both together.
- Receivers **must ignore unknown packet types**. New features add new types; never change the meaning or layout of an existing type without a protocol version bump.
- The sender must send `HELLO` immediately after connecting. The receiver only promotes a connection to the active session after it has received data (this defends against Network.framework "Happy Eyeballs" opening parallel connections and abandoning the losers).
- The sender must send `PING` at least every second and `BYE` before a deliberate disconnect. The receiver treats 4 s of silence as a lost connection. Never rely on TCP FIN alone; it is not delivered reliably when the sender process exits.
- Payload sizes are bounded (`Protocol.MAX_PAYLOAD`); validate lengths before allocating.

---

## 6. Swift rules (`mac/`)

Style:
- Swift 5 language mode (`-swift-version 5`). Four-space indentation, 120-column soft limit.
- One responsibility per type; keep types `final` unless designed for subclassing.
- Prefer `guard` for early exits; no force unwraps (`!`) except for values that are provably non-nil at compile time (e.g. a literal URL).
- Errors that reach the user are `EngineError` with a human-readable message; do not `exit()` from library code. Only `mac/cli/main.swift` may call `exit()`.

Concurrency (each rule below prevented a real bug):
- Each component owns one serial `DispatchQueue`. **Never `queue.sync` into another component's queue** from a callback that might already be running on a queue that component waits on — this deadlocked capture ↔ network before. Use `async` for cross-queue hand-offs.
- Network sends go through `Sender.send`, which is thread-safe; never touch `NWConnection` directly from other queues.
- `StreamSession` events are delivered on the main queue; UI code may assume main-thread delivery.
- Stopping must be idempotent: `StreamSession.finish` may be reached from several queues at once.

Capture and audio:
- ScreenCaptureKit only delivers frames when the screen changes; never treat "no frames" as a failure.
- When "play sound only on the TV" is enabled, audio comes from `SystemAudioTap` (Core Audio process tap with `muteBehavior = .muted`). **Do not mute or change the volume of the user's output device** to silence the Mac — macOS un-mutes it when the user presses a volume key. Volume keys are forwarded to the TV via `OutputVolumeMonitor` and the `VOLUME` packet.
- Every resource created for a session (tap, aggregate device, IOProc, listeners, `SCStream`, `VTCompressionSession`) must be released in `stop()`, including on error paths.
- `SystemAudioMuter.recoverIfNeeded()` exists to undo device mutes left by older versions; keep calling it at launch.

---

## 7. Kotlin rules (`android/`)

Style:
- Kotlin official code style, four-space indentation, trailing commas in multi-line parameter lists.
- No `!!`. Prefer `?.let`, `?: return`, `requireNotNull` with a message.
- Compose: stateless composables that take state + callbacks; state hoisted to `ReceiverViewModel`. Use `collectAsStateWithLifecycle()`.
- TV UI: every screen must work with a D-pad only, keep content inside the overscan safe area (≈ 48–64 dp horizontal, 27–40 dp vertical), and use the theme colours in `ui/theme/Theme.kt`.

Architecture:
- `net/` has no Android UI dependencies; `Protocol.kt` is pure Kotlin and unit-tested on the JVM.
- `StreamServer` owns the accept loop and the single active session; `StreamSession.run()` blocks an IO thread until the session ends and always returns an `EndReason`.
- `ReceiverViewModel` is the only place that maps engine callbacks (called on IO threads) to `ReceiverUiState`. Ignore callbacks whose `sessionId` is not the active session.
- The server runs only while the activity is started (`onStart`/`onStop`).

Media (each rule below prevented a real bug):
- `VideoDecoder`: call `MediaCodec.release()` directly; **do not call `stop()`** (it hangs on some TV SoCs). Bound every `dequeueInputBuffer` wait; drop the frame and wait for the next key frame rather than blocking forever.
- Render decoded frames with `releaseOutputBuffer(index, System.nanoTime())`; never use the sender's PTS as a display time.
- `AudioPlayer`: call `pause()`/`flush()` **before** joining the writer thread and `release()`; releasing while `write()` is blocked can hang.
- Never allocate a new buffer per packet on the hot path; `PacketReader` reuses its buffer — copy only when the data outlives the next read (audio).

---

## 8. Testing

- Android: JVM unit tests live in `android/app/src/test/`. Every protocol change needs tests for valid input, truncated input and out-of-range values.
- Swift: unit tests will live in `macos/Tests/` after the Swift Package migration (see `docs/OPEN_SOURCE_PLAN.md`). Until then, verify Swift changes end to end against a TV.
- Prefer real-device verification for anything involving MediaCodec, AudioTrack, ScreenCaptureKit or Core Audio — emulators and mocks do not reproduce their failure modes.

---

## 9. Git and pull requests

- Branch from `main`; branch names `feat/…`, `fix/…`, `docs/…`, `refactor/…`, `chore/…`.
- Commits follow Conventional Commits: `type(scope): imperative summary` (scopes: `mac`, `cli`, `app`, `tv`, `protocol`, `build`, `docs`, `ci`).
- One logical change per PR; describe what changed, why, and how it was verified (commands and device used).
- Do not commit build outputs (`build/`, `android/**/build/`), `android/local.properties`, keystores, `keystore.properties`, certificates, logs or screenshots of a user's screen.
- Never rewrite published history on `main`.

---

## 10. Security and privacy

- Never commit secrets: signing identities, keystores, passwords, API tokens, Apple ID credentials.
- Release signing configuration is read from `android/keystore.properties` (git-ignored) or CI secrets; the debug keystore fallback is for local builds only.
- The current protocol is **unauthenticated and unencrypted**. Do not add features that send data beyond the screen and audio the user chose to share, and do not add telemetry or network traffic outside the LAN.
- Treat all bytes from the network as untrusted: validate lengths and enum values; malformed input must end the session, not crash the app.

---

## 11. Things agents must not do

- Change application IDs, bundle identifiers, signing identities or the release keystore.
- Change the user's macOS audio settings (volume, mute, default device) as a side effect of code paths, or leave them changed after testing.
- Disable lint rules, tests or warnings to make a build pass.
- Introduce new dependencies without stating why in the PR; prefer platform APIs.
- Publish releases, push tags, change repository visibility or settings without explicit maintainer approval.
