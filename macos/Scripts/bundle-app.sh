#!/bin/bash
# Builds Beamly.app and the beamly CLI in release mode and signs them.
#
# Usage: macos/Scripts/bundle-app.sh [output-dir]
#
# Environment:
#   SIGN_IDENTITY   Code-signing identity. Defaults to the first "Developer ID Application" identity,
#                   then the first "Apple Development" identity, then ad-hoc ("-").
#                   A stable identity matters: macOS ties Screen Recording and System Audio Recording
#                   permissions to it, so ad-hoc builds lose those permissions on every rebuild.
#   BUILD_NUMBER    CFBundleVersion (default: number of commits).
#   UNIVERSAL=1     Build for both arm64 and x86_64 (used for releases).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/build}"
VERSION="$(cat "$ROOT/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="$OUT/Beamly.app"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGN_IDENTITY="$(echo "$IDENTITIES" | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="$(echo "$IDENTITIES" | awk -F'"' '/Apple Development/ {print $2; exit}')"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
fi

BUILD_FLAGS=(--package-path "$ROOT/macos" -c release)
[ "${UNIVERSAL:-0}" = "1" ] && BUILD_FLAGS+=(--arch arm64 --arch x86_64)

echo "==> swift build (release${UNIVERSAL:+, universal})"
swift build "${BUILD_FLAGS[@]}" --product beamly
swift build "${BUILD_FLAGS[@]}" --product BeamlyApp
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

echo "==> Bundling $APP ($VERSION build $BUILD_NUMBER)"
mkdir -p "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/BeamlyApp" "$APP/Contents/MacOS/Beamly"
sed -e "s/\$(VERSION)/$VERSION/" -e "s/\$(BUILD_NUMBER)/$BUILD_NUMBER/" \
    "$ROOT/macos/App/Info.plist" > "$APP/Contents/Info.plist"
cp -R "$ROOT/macos/App/Resources/"*.lproj "$APP/Contents/Resources/"

ICNS="$OUT/.cache/AppIcon.icns"
if [ ! -f "$ICNS" ]; then
    ICONSET="$OUT/.cache/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    swift "$ROOT/macos/Scripts/make_icon.swift" "$OUT/.cache/icon_1024.png"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$OUT/.cache/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$OUT/.cache/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
# The CLI ships inside the app (for the Homebrew cask) and next to it.
cp "$BIN/beamly" "$APP/Contents/Helpers/beamly"
cp "$BIN/beamly" "$OUT/beamly"

echo "==> Signing with: $SIGN_IDENTITY"
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
[ "$SIGN_IDENTITY" = "-" ] || SIGN_FLAGS+=(--options runtime --timestamp)
codesign "${SIGN_FLAGS[@]}" "$OUT/beamly"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Helpers/beamly"   # nested code is signed before its container
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict "$APP"
echo "    $APP"
echo "    $OUT/beamly"
