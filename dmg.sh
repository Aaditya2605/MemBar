#!/bin/bash
# Makes build/MemBar-<version>.dmg for a GitHub release: the release app and a link to
# Applications, in a window that says to drag one onto the other.
#
#   ./dmg.sh                                       ad hoc: macOS asks for "Open Anyway"
#   SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=name ./dmg.sh
#                                                  signed, notarized and stapled
#
# NOTARY_PROFILE: credentials saved once with `xcrun notarytool store-credentials name`.
# Needs create-dmg and rsvg-convert (brew install create-dmg librsvg). create-dmg lays the
# window out through Finder: the first time, macOS asks to allow control of Finder.
set -euo pipefail

cd "$(dirname "$0")"
./build.sh  # signs with SIGN_ID when it is set
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/MemBar.app/Contents/Info.plist)

# New folders each time: create-dmg copies all of the app folder into the image.
STAGE=$(mktemp -d) ART=$(mktemp -d)
ditto build/MemBar.app "$STAGE/MemBar.app"
# The background at 1x and 2x in one TIFF, so it is sharp on Retina screens.
rsvg-convert -w 540 -h 380 Resources/dmg-background.svg -o "$ART/bg.png"
rsvg-convert -w 1080 -h 760 Resources/dmg-background.svg -o "$ART/bg@2x.png"
tiffutil -cathidpicheck "$ART/bg.png" "$ART/bg@2x.png" -out "$ART/background.tiff"

extra=()
[ -n "${SIGN_ID:-}" ] && extra+=(--codesign "$SIGN_ID")
[ -n "${NOTARY_PROFILE:-}" ] && extra+=(--notarize "$NOTARY_PROFILE")  # waits for Apple, then staples
create-dmg --overwrite --volname "MemBar" --volicon Resources/AppIcon.icns \
    --background "$ART/background.tiff" --window-size 540 380 --icon-size 128 \
    --icon "MemBar.app" 140 190 --hide-extension "MemBar.app" --app-drop-link 400 190 \
    ${extra[@]+"${extra[@]}"} "build/MemBar-$VERSION.dmg" "$STAGE"
echo "built: build/MemBar-$VERSION.dmg"
