# Open-Source Readiness Plan

Status: **Draft** · Owner: @ledhcg · Last updated: 2026-11-24

This plan takes the repository from a private prototype to a public, professionally maintained
open-source project. Phases are ordered by dependency; each phase ends with a checklist that must be
fully ticked before the next phase starts.

---

## 0. Decisions required before any work

| # | Decision | Options | Recommendation |
|---|----------|---------|----------------|
| D1 | **Project name** | Keep "Mac2TV" / rename | **Rename.** Apple's trademark guidelines only allow "Mac" in a third-party name when it is paired with a non-generic word, is not more prominent than the rest of the name, and Apple's ownership is acknowledged. "Mac2TV" (Mac + a generic word) is close to Apple's own *unacceptable* examples, and App Review has rejected "Mac"-prefixed names. Pick a neutral name and describe compatibility as "for macOS". |
| D2 | **License** | MIT / Apache-2.0 / GPL-3.0 | **Apache-2.0** — permissive like MIT, plus an explicit patent grant, which matters for a project that touches media codecs. |
| D3 | **macOS distribution** | Unsigned build / Developer ID + notarization | **Developer ID + notarization** (requires the paid Apple Developer Program). Unsigned apps are blocked by Gatekeeper and need screen/audio permissions to be re-granted on every update. |
| D4 | **Android distribution** | GitHub Releases APK / Google Play / F-Droid | **GitHub Releases** first; Play Store later (needs a store listing and a privacy policy). |
| D5 | **Minimum versions** | — | macOS 14.2 (Core Audio process taps), Android 8.0 / API 26. |
| D6 | **Security baseline for 1.0** | Ship as-is / pairing + encryption | **Pairing + encryption before 1.0** (see Phase 5). Today any device on the LAN can stream to the TV. |

---

## Phase 1 — English-only codebase

Goal: every artifact a contributor reads is in English; Vietnamese becomes a translation.

- [ ] Translate all code comments, log messages, error strings and commit-facing text in `mac/` and `android/` to English.
- [ ] macOS: move user-facing strings (menu items, alerts, status text, CLI output) into a String Catalog (`Localizable.xcstrings`) with `en` as the development language and `vi` as a translation.
- [ ] Android: make `values/strings.xml` (English) the source of truth; keep `values-vi/` as a translation. No hard-coded user-facing strings in Kotlin.
- [ ] Remove or gate developer-only hooks: the `--connect` launch argument and the always-on file log (`~/Library/Logs/Mac2TV.log`) become a documented `--debug` flag.
- [ ] Rewrite the initial commit message in English (history is a single commit, so this is a cheap amend before going public).

**Exit criteria:** `grep` for Vietnamese diacritics outside `values-vi/` and the `vi` string catalog returns nothing.

---

## Phase 2 — Project structure

Goal: a layout that new contributors understand in five minutes and that CI can build without the maintainer's machine.

```
.
├── AGENTS.md                 # Rules for AI coding agents (shared)
├── CLAUDE.md                 # Imports AGENTS.md
├── README.md
├── LICENSE
├── CHANGELOG.md
├── CONTRIBUTING.md · CODE_OF_CONDUCT.md · SECURITY.md · SUPPORT.md
├── docs/
│   ├── ARCHITECTURE.md       # Components, threading, data flow diagrams
│   ├── PROTOCOL.md           # Normative wire-protocol spec (versioned)
│   └── RELEASING.md
├── protocol/test-vectors/    # Binary fixtures shared by Swift and Kotlin tests
├── macos/                    # Swift package
│   ├── Package.swift
│   ├── Sources/StreamKit/    # Library: capture, encode, audio tap, network, discovery
│   ├── Sources/mac2tv-cli/   # CLI target
│   ├── Sources/MenuBarApp/   # App target
│   ├── Tests/StreamKitTests/
│   └── Scripts/bundle-app.sh # Builds, signs and packages the .app
├── android/                  # Gradle project (unchanged layout)
└── .github/                  # Workflows, issue forms, PR template, CODEOWNERS, dependabot
```

- [ ] Split `mac/Engine.swift` (~800 lines) into one type per file inside a `StreamKit` library target.
- [ ] Convert the macOS build to Swift Package Manager; keep a thin script only for `.app` bundling and signing.
- [ ] Add protocol versioning: `HELLO` carries `u16 protocolVersion` before the device name; receivers reject unsupported major versions with a clear on-screen message.
- [ ] Write `docs/PROTOCOL.md` as the single source of truth for packet types; add shared binary test vectors consumed by both test suites.
- [ ] Add Swift unit tests: packet framing, AVCC → Annex-B conversion, volume payload encoding, discovery filtering.

**Exit criteria:** `swift build && swift test` (macOS) and `./gradlew check` (Android) pass from a clean clone.

---

## Phase 3 — Quality gates and CI

| Concern | macOS | Android |
|---------|-------|---------|
| Formatting | `swift-format` | `ktlint` (via Spotless) |
| Static analysis | SwiftLint | Android Lint (`abortOnError`) + detekt |
| Tests | `swift test` | `./gradlew testReleaseUnitTest` |
| Build | `swift build -c release` + app bundle | `./gradlew assembleRelease` |

- [ ] `.editorconfig` at the root.
- [ ] GitHub Actions: `ci.yml` (macOS job on `macos-15`, Android job on `ubuntu-latest` with JDK 17), triggered on pull requests and `main`.
- [ ] CodeQL scanning for Swift and Kotlin.
- [ ] Dependabot for `gradle` and `github-actions`.
- [ ] OpenSSF Scorecard workflow; pin third-party actions by commit SHA.
- [ ] Branch protection on `main`: required CI, required review, linear history, no force-push.

**Exit criteria:** a PR that breaks formatting, lint, tests or build cannot be merged.

---

## Phase 4 — Documentation and community health files

- [ ] **README.md**: name + one-line value proposition, demo GIF, feature list, requirements, install (Homebrew cask + APK), quick start, "How it works" diagram, troubleshooting (permissions, firewall, same network), roadmap link, license, trademark notice ("Mac and macOS are trademarks of Apple Inc. This project is not affiliated with Apple.").
- [ ] **CONTRIBUTING.md**: dev setup for both platforms, branch/commit conventions, how to run checks, how to test on a real TV with `adb`.
- [ ] **CODE_OF_CONDUCT.md**: Contributor Covenant.
- [ ] **SECURITY.md**: supported versions, private vulnerability reporting via GitHub, response timeline, current threat model (unauthenticated LAN stream until Phase 5).
- [ ] **SUPPORT.md**, **CHANGELOG.md** (Keep a Changelog format), **CODEOWNERS**.
- [ ] `.github/ISSUE_TEMPLATE/` issue forms (bug report with macOS/TV model/logs, feature request) + `config.yml` linking to Discussions.
- [ ] `.github/pull_request_template.md` with the definition-of-done checklist from `AGENTS.md`.
- [ ] `docs/ARCHITECTURE.md` with the capture → encode → network → decode → render pipeline and the threading model.

**Exit criteria:** GitHub's Community Standards page shows every item as complete.

---

## Phase 5 — Security and privacy hardening (blocks 1.0)

Current risks:

1. **No authentication** — any device on the LAN can connect to port 7878 and take over the TV screen.
2. **No encryption** — screen contents and audio travel in clear text on the LAN.
3. **Audio routing side effects** — the Mac's local output is silenced while streaming; a crash must never leave the user without sound.

Planned work:

- [ ] Pairing: TV shows a 6-digit code; the Mac stores a per-TV key after the first successful pairing.
- [ ] Transport encryption: TLS 1.3 with the paired key (or Noise protocol framework); bump the protocol major version.
- [ ] "Allow connections from" setting on the TV (paired Macs only / anyone on this network).
- [ ] Fuzz tests for `PacketReader` and `VideoConfig.parse` (malformed input must never crash the receiver).
- [ ] Privacy statement in the README: no telemetry, no network traffic outside the LAN.

---

## Phase 6 — Release engineering

- [ ] Semantic Versioning, one version shared by the Mac app, CLI and TV app; tags `vX.Y.Z`.
- [ ] `release.yml` triggered by tags:
  - macOS: build → sign with Developer ID → `notarytool submit --wait` → staple → DMG + ZIP.
  - Android: build release APK signed with the release keystore stored in GitHub encrypted secrets.
  - Generate release notes from `CHANGELOG.md`; attach artifacts and SHA-256 checksums.
- [ ] Homebrew tap (`<owner>/homebrew-tap`) with a cask updated automatically on release.
- [ ] `docs/RELEASING.md` describing the manual fallback.

---

## Phase 7 — Going public

- [ ] Secret scan of the full history (`gitleaks`), confirm no keystores, certificates, tokens or personal data.
- [ ] Enable: private vulnerability reporting, Discussions, Dependabot alerts, secret scanning, push protection.
- [ ] Repository metadata: description, topics (`screen-mirroring`, `android-tv`, `macos`, `screencapturekit`, `h264`), social preview image.
- [ ] Switch visibility to public; publish `v1.0.0`.
- [ ] Apply for the OpenSSF Best Practices badge (passing level).

---

## Product roadmap after 1.0 (for the README)

- Audio/video synchronisation (presentation timestamps on the receiver).
- Adaptive bitrate based on receiver feedback.
- HEVC when the TV decoder supports it.
- Extend-display mode (virtual second display) in addition to mirroring.
- Remote input: TV remote → Mac media keys.

---

## References

- AGENTS.md open format: https://agents.md · https://addyosmani.com/agents/15-agents-md/
- Claude Code memory and `@` imports: https://code.claude.com/docs/en/memory
- GitHub community profile: https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/about-community-profiles-for-public-repositories
- Apple trademark guidelines: https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html
- Apple notarization: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- OpenSSF Scorecard: https://github.com/ossf/scorecard · Best Practices Badge: https://www.bestpractices.dev
