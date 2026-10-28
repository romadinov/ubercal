#!/bin/bash
# Builds Ubercal.app without an Xcode project. Usage: ./build.sh [install]
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Ubercal.app
# A stable signing identity keeps the Calendars permission across rebuilds; ad-hoc ("-") re-prompts each time.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
SIGN_ID="${SIGN_ID:--}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tmp
cp Info.plist "$APP/Contents/"

# Icon: render once at 1024 and let sips/iconutil derive the .icns sizes.
ICONSET=build/tmp/AppIcon.iconset
mkdir -p "$ICONSET"
swiftc -O scripts/make-icon.swift -o build/tmp/make-icon
build/tmp/make-icon build/tmp/icon-1024.png
for s in 16 32 128 256 512; do
    sips -z $s $s build/tmp/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/tmp/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macos26.0" \
    Sources/*.swift -o "$APP/Contents/MacOS/Ubercal"
codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $APP (signed: $SIGN_ID)"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Ubercal || true
    rm -rf /Applications/Ubercal.app
    cp -R "$APP" /Applications/
    open /Applications/Ubercal.app
    echo "Installed to /Applications"
fi
