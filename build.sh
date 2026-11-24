#!/bin/bash
# Builds everything and runs the unit tests:
#   build/Beamly.app       macOS menu bar app
#   build/beamly           macOS command-line sender
#   build/beamly-tv.apk    Android TV receiver
set -euo pipefail
cd "$(dirname "$0")"

echo "==> macOS: tests"
swift test --package-path macos

macos/Scripts/bundle-app.sh build

echo "==> Android TV: tests, lint and release APK"
# Gradle 8.14 / AGP 8.7 need JDK 17-24; the JBR bundled with Android Studio may be newer.
GRADLE_JAVA="${GRADLE_JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
[ -d "$GRADLE_JAVA" ] || GRADLE_JAVA="${JAVA_HOME:-}"
(cd android && JAVA_HOME="$GRADLE_JAVA" ./gradlew --quiet spotlessCheck check assembleRelease)
cp android/app/build/outputs/apk/release/app-release.apk build/beamly-tv.apk

echo "==> Done"
echo "    build/Beamly.app"
echo "    build/beamly"
echo "    build/beamly-tv.apk"
