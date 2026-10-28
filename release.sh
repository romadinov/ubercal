#!/bin/bash
# Builds a Developer ID-signed Ubercal.zip and publishes it as a GitHub release.
# Usage: ./release.sh            (tag = v<CFBundleShortVersionString>)
# Notarization runs when NOTARY_PROFILE names a notarytool keychain profile:
#   xcrun notarytool store-credentials ubercal --apple-id <you@…> --team-id SZVSSCJQFN
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
TAG="v$VERSION"
APP=build/Ubercal.app
ZIP=build/Ubercal-$VERSION.zip
DEV_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[[ -n "$DEV_ID" ]] || { echo "No Developer ID Application certificate"; exit 1; }

./build.sh
codesign --force --options runtime --timestamp --entitlements Ubercal.entitlements --sign "$DEV_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    NOTE="Signed with Developer ID and notarized."
else
    NOTE="Signed with Developer ID (not notarized): after unzipping, right-click Ubercal → Open the first time, or run \`xattr -dr com.apple.quarantine Ubercal.app\`."
fi

gh release create "$TAG" "$ZIP" --title "Ubercal $VERSION" \
    --notes "Menu bar calendar for macOS 26+, built on the system Calendar (EventKit). $NOTE"
