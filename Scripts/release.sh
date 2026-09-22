#!/bin/zsh
# Archive, sign with Developer ID, notarize, staple and zip Relay.
#
# One-time setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials relay-notary --apple-id <apple-id> --team-id 82FKKV622Q
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=${NOTARY_PROFILE:-relay-notary}
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"

xcodebuild -project Relay.xcodeproj -scheme Relay -configuration Release \
  -archivePath "$OUT/Relay.xcarchive" archive
xcodebuild -exportArchive -archivePath "$OUT/Relay.xcarchive" \
  -exportOptionsPlist Scripts/ExportOptions.plist -exportPath "$OUT"

ditto -c -k --keepParent "$OUT/Relay.app" "$OUT/Relay-notarize.zip"
xcrun notarytool submit "$OUT/Relay-notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Relay.app"

VERSION=$(defaults read "$PWD/$OUT/Relay.app/Contents/Info.plist" CFBundleShortVersionString)
ditto -c -k --keepParent "$OUT/Relay.app" "$OUT/Relay-$VERSION.zip"
rm "$OUT/Relay-notarize.zip"
echo "Ready: $OUT/Relay-$VERSION.zip"
