#!/bin/bash
# Build, sign, notarize and staple BlinkenLights, then package a notarized DMG.
#
# Usage: scripts/release.sh [destination-folder]
#
#   destination-folder  optional; the finished DMG is also copied here
#
# Environment overrides:
#   NOTARY_PROFILE  notarytool keychain profile (default: BlinkenLights-notary)
#   SIGN_IDENTITY   codesign identity        (default: "Developer ID Application")
#
# One-time setup of the notary profile (App Store Connect API team key):
#   xcrun notarytool store-credentials BlinkenLights-notary \
#     --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
#     --key-id <KEYID> --issuer <ISSUER-UUID>
#
# Output: build/release/BlinkenLights-<version>.dmg
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/build/release"
# Work outside the repo: iCloud-synced folders (e.g. ~/Documents) re-add
# FinderInfo attributes that make strict signature checks fail.
WORK="$(mktemp -d -t blinkenlights-release)"
trap 'rm -rf "$WORK"' EXIT
DEST="${1:-}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-BlinkenLights-notary}"

if [ -n "$DEST" ] && [ ! -d "$DEST" ]; then
  echo "Destination folder not found: $DEST" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "== Build"
if command -v xcodegen >/dev/null; then
  (cd "$REPO" && xcodegen generate --quiet)
fi
xcodebuild -project "$REPO/BlinkenLights.xcodeproj" -scheme BlinkenLights -configuration Release \
  -derivedDataPath "$WORK/dd" build 2>&1 | grep -E "error|BUILD SUCCEEDED|BUILD FAILED" | sort -u
BUILT="$WORK/dd/Build/Products/Release/BlinkenLights.app"
[ -d "$BUILT" ] || { echo "Build failed" >&2; exit 1; }
VERSION=$(defaults read "$BUILT/Contents/Info" CFBundleShortVersionString)

mkdir -p "$WORK/stage"
APP="$WORK/stage/BlinkenLights.app"
ditto --norsrc --noextattr "$BUILT" "$APP"

echo "== Sign app (hardened runtime, secure timestamp)"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --deep --strict "$APP"

echo "== Notarize and staple app"
ditto -c -k --keepParent "$APP" "$WORK/app.zip"
xcrun notarytool submit "$WORK/app.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$WORK/app.zip"

echo "== Build, sign, notarize and staple DMG"
ln -s /Applications "$WORK/stage/Applications"
DMG="$WORK/BlinkenLights-$VERSION.dmg"
hdiutil create -quiet -volname "BlinkenLights $VERSION" -srcfolder "$WORK/stage" \
  -fs HFS+ -format UDZO -ov "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "== Gatekeeper checks"
spctl -a -vv "$APP"
spctl -a -vv -t open --context context:primary-signature "$DMG"
xcrun stapler validate "$DMG"

cp -f "$DMG" "$OUT/"
if [ -n "$DEST" ]; then
  cp -f "$DMG" "$DEST/"
  echo "Copied to $DEST/$(basename "$DMG")"
fi

echo "Done: $OUT/$(basename "$DMG")"
