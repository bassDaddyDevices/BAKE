#!/bin/bash
# Builds BAKE for distribution outside the App Store: archive, export with Developer ID, notarize and
# staple the app, wrap it in a DMG, notarize and staple that, and check Gatekeeper and Apple's
# distribution check accept both. Produces build/release/BAKE-<version>.dmg.
#
# One-time setup (stores your notarization login in the Keychain; nothing secret goes in this repo):
#   1. appleid.apple.com > Sign-In and Security > App-Specific Passwords: make one called "BAKE notary".
#   2. xcrun notarytool store-credentials BAKE-notary \
#        --apple-id <your Apple ID email> --team-id Z427P979RG --password <that app-specific password>
#
# Then, from the repository root:   scripts/notarize.sh
# Dry run (archive, export and sign, but don't send to Apple):   scripts/notarize.sh --no-notarize
set -euo pipefail

PROFILE="${BAKE_NOTARY_PROFILE:-BAKE-notary}"
NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/BAKE.xcarchive"
EXPORT="$OUT/export"
rm -rf "$OUT"
mkdir -p "$OUT"

step() { printf '\n==> %s\n' "$1"; }

step "Archiving (Release)"
xcodebuild archive \
    -workspace "$ROOT/BAKE_WORKSPACE.xcworkspace" -scheme BAKE -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -quiet

step "Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist" -quiet
APP="$EXPORT/BAKE.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

step "Checking the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Hardened runtime and the Developer ID authority are what notarization requires.
codesign --display --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime" \
    || { echo "error: not signed with Developer ID and the hardened runtime" >&2; exit 1; }

# Sends a file to Apple and waits; stops the script with Apple's log if it isn't accepted.
notarize() {
    local file="$1" report="$OUT/notary-$(basename "$1").json"
    xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json > "$report"
    local status id
    status="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$report")"
    if [[ "$status" != "Accepted" ]]; then
        id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$report")"
        echo "error: notarization of $(basename "$file") $status. Apple's log:" >&2
        xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
        exit 1
    fi
}

# The app gets its own ticket first: people drag it out of the DMG, and a stapled app opens
# offline on first launch instead of asking Apple's servers.
if [[ $NOTARIZE == 1 ]]; then
    step "Notarizing the app (this usually takes a few minutes)"
    ditto -c -k --keepParent "$APP" "$OUT/BAKE-app.zip"
    notarize "$OUT/BAKE-app.zip"
    step "Stapling the app"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

DMG="$OUT/BAKE-$VERSION.dmg"
step "Making $(basename "$DMG")"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "BAKE $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
# By fingerprint: two certificates with the same name make signing by name ambiguous.
IDENTITY="${BAKE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Developer ID Application/ { print $2; exit }')}"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ $NOTARIZE == 0 ]]; then
    step "Dry run done (not notarized): $DMG"
    exit 0
fi

step "Notarizing the DMG"
notarize "$DMG"

step "Stapling the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

step "Checking the app inside, as a download would arrive"
MOUNT="$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/\/Volumes\// { print $NF }')"
xcrun stapler validate "$MOUNT/BAKE.app"
syspolicy_check distribution "$MOUNT/BAKE.app"
hdiutil detach -quiet "$MOUNT"

step "Checking Gatekeeper"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

step "Done: $DMG (version $VERSION, build $BUILD)"
