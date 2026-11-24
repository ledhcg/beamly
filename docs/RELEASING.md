# Releasing

Beamly uses [Semantic Versioning](https://semver.org/). One version, stored in the root `VERSION` file, applies to
the macOS app, the CLI and the TV app (Android `versionCode` = `MAJOR*10000 + MINOR*100 + PATCH`).

## One-time setup

Configure these **repository secrets** (Settings → Secrets and variables → Actions). Every secret is optional: a
release still builds without them, but the result is weaker as described.

| Secret | Purpose | Without it |
|--------|---------|------------|
| `MACOS_CERTIFICATE_P12_BASE64` | Developer ID Application certificate + private key, exported as `.p12`, base64-encoded | App is ad-hoc signed; Gatekeeper blocks it |
| `MACOS_CERTIFICATE_PASSWORD` | Password of the `.p12` | — |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Jane Doe (TEAMID)` | — |
| `APPLE_API_KEY_P8_BASE64` | App Store Connect API key (`.p8`, base64) with the *Developer* role, for notarization | Not notarized |
| `APPLE_API_KEY_ID` | Key ID of that API key | — |
| `APPLE_API_ISSUER_ID` | Issuer ID of that API key | — |
| `ANDROID_KEYSTORE_BASE64` | Release keystore (`.jks`, base64) | No APK is attached |
| `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Keystore credentials | — |
| `HOMEBREW_TAP_TOKEN` | Fine-grained token with *Contents: read and write* on the tap repository | Cask not updated |

Optional repository variable `HOMEBREW_TAP_REPO` (default `<owner>/homebrew-tap`).

Notes:
- A Developer ID certificate requires a paid Apple Developer Program membership.
- **Keep the Android keystore safe and backed up.** Android refuses to upgrade an app signed with a different key;
  losing it forces every user to uninstall and reinstall. Create it once:
  `keytool -genkeypair -v -keystore beamly-release.jks -alias beamly -keyalg RSA -keysize 4096 -validity 10000`
  then `base64 -i beamly-release.jks | pbcopy`.
- Create the tap repository `homebrew-tap` (public, empty) before the first published release.

## Cutting a release

1. Make sure `main` is green.
2. Update `VERSION`, and move the **Unreleased** entries in `CHANGELOG.md` into a new `## [X.Y.Z] - YYYY-MM-DD`
   section (update the comparison links at the bottom).
3. Open a pull request `chore(release): X.Y.Z`, get it reviewed and merged.
4. Tag the merge commit and push the tag:
   ```sh
   git checkout main && git pull
   git tag -s vX.Y.Z -m "Beamly X.Y.Z"   # -s requires a configured signing key; use -a otherwise
   git push origin vX.Y.Z
   ```
5. The **Release** workflow verifies the tag against `VERSION` and `CHANGELOG.md`, runs the tests, builds a universal,
   signed and notarized `Beamly-X.Y.Z.dmg`, the CLI zip, the signed APK and `SHA256SUMS.txt`, and creates a
   **draft** GitHub release with the changelog section as notes.
6. Download the artifacts from the draft, smoke-test them on a Mac and a TV, then **Publish** the release.
7. Publishing triggers the **Update Homebrew cask** workflow (`brew install --cask <owner>/tap/beamly`).

## Manual fallback

```sh
UNIVERSAL=1 SIGN_IDENTITY="Developer ID Application: …" macos/Scripts/bundle-app.sh dist
hdiutil create -volname Beamly -srcfolder dist/Beamly.app -ov -format UDZO dist/Beamly-X.Y.Z.dmg
xcrun notarytool submit dist/Beamly-X.Y.Z.dmg --keychain-profile <profile> --wait
xcrun stapler staple dist/Beamly-X.Y.Z.dmg
(cd android && ./gradlew assembleRelease)   # with android/keystore.properties present
```
