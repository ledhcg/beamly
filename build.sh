#!/bin/bash
# Build mac2tv: CLI + app thanh menu cho macOS, APK cho Android TV.
set -euo pipefail
cd "$(dirname "$0")"


echo "==> Build Mac CLI (mac2tv)"
mkdir -p build
swiftc -O -swift-version 5 mac/Engine.swift mac/cli/main.swift -o build/mac2tv

echo "==> Build Mac menu bar app (Mac2TV.app)"
APP=build/Mac2TV.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 mac/Engine.swift mac/app/main.swift -o "$APP/Contents/MacOS/Mac2TV"
cp mac/app/Info.plist "$APP/Contents/Info.plist"
if [ ! -f build/AppIcon.icns ]; then
    ICONSET=build/AppIcon.iconset; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    swift mac/app/make_icon.swift build/icon_1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ký bằng chứng chỉ Apple Development nếu có (giữ quyền Screen Recording qua các lần build), không thì ký ad-hoc.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --options runtime --sign "${SIGN_ID:--}" "$APP"
codesign --force --sign "${SIGN_ID:--}" build/mac2tv

echo "==> Build Android TV APK (Gradle, release)"
# AGP cần JDK 17–24; JBR của Android Studio có thể là bản mới hơn.
GRADLE_JAVA="${GRADLE_JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
[ -d "$GRADLE_JAVA" ] || GRADLE_JAVA="$JAVA_HOME"
(cd android && JAVA_HOME="$GRADLE_JAVA" ./gradlew --quiet testReleaseUnitTest assembleRelease)
cp android/app/build/outputs/apk/release/app-release.apk build/mac2tv-receiver.apk

echo "==> Xong:"
echo "    build/mac2tv               (lệnh Terminal)"
echo "    build/Mac2TV.app           (app thanh menu)"
echo "    build/mac2tv-receiver.apk  (cài lên TV)"
