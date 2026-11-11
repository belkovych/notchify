#!/bin/bash
# Builds build/Notchify.app. Pass "run" to (re)launch it afterwards.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Notchify.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 \
    Sources/*.swift -o "$APP/Contents/MacOS/Notchify"
cp Info.plist "$APP/Contents/Info.plist"

# A real signing identity keeps the Spotify automation permission across rebuilds;
# ad-hoc signing works too but macOS asks again after every build.
IDENTITY="${NOTCHIFY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -z "$IDENTITY" ] || ! codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    codesign --force --sign - "$APP"
    echo "signed ad-hoc"
else
    echo "signed with: $IDENTITY"
fi

if [ "${1:-}" = "run" ]; then
    pkill -x Notchify 2>/dev/null || true
    sleep 0.3
    open "$APP"
fi
