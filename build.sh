#!/bin/bash
# Makes build/MemBar.app around the SwiftPM binary.
#
#   ./build.sh           release build, ad-hoc signed: runs on this Mac
#   ./build.sh debug     debug build
#   SIGN_ID="Developer ID Application: …" ./build.sh
#                        signed for other Macs, with the hardened runtime that notarization needs
#   ./dmg.sh             the release DMG (see there)
#
#   open build/MemBar.app      run it (menu bar only, no Dock icon)
#
#   MemBar=build/MemBar.app/Contents/MacOS/MemBar; the flags (same as $MemBar --help):
#   $MemBar --list                          groups as text
#   $MemBar --json [--cpu]                  groups, RAM, swap, pressure as JSON; --cpu adds CPU %
#   $MemBar --leftovers                     one per line; exit 1 if any
#   $MemBar --stop [NAME ...] [--dry-run]   stop all or the named leftovers; not as root
#   $MemBar --test                          self-check of the pure rules (prints ok)
#   $MemBar --snapshot OUT.png [QUERY]      debug builds: the panel as a PNG; env CROWD=1 HISTORY=1
#                                           MARK=1 FIRSTRUN=1 DARK=0|1 add to it; LEGEND=1 or
#                                           INSPECT=sample|files|env draw that instead
#   $MemBar --snapshot-details OUT.png GROUP [QUERY]   debug builds: the Details window as a PNG
#   .build/debug/MemBar --drive OUTDIR      debug builds: the real app through a scripted run (about 40 s,
#                                           it takes the focus): a PNG per step, drive.log. The bare binary
#                                           only: an .app has the installed app's settings
#   $MemBar --help, -h                      every flag
#   .build/debug/MemBar --agent-test HOME LABEL   debug test hook, not in --help: Disable and enable
#                                           again a loaded com.appmem.test.* agent in HOME
#
#   open appmem://report       copy a Markdown report (also appmem://open, appmem://refresh)
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
VERSION=0.1.2
APP="build/MemBar.app"

swift build -c "$CONFIG"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Copy, then rename over the old binary: a new file, so a copy that runs is not
# changed under it, and macOS does not keep the old code signature.
cp ".build/$CONFIG/MemBar" "$APP/Contents/MacOS/MemBar.new"
mv -f "$APP/Contents/MacOS/MemBar.new" "$APP/Contents/MacOS/MemBar"
# The app icon: Resources/AppIcon.svg. After a change to the SVG, make the .icns again:
#   mkdir -p /tmp/AppIcon.iconset && for s in 16 32 128 256 512; do rsvg-convert -w $s -h $s Resources/AppIcon.svg -o /tmp/AppIcon.iconset/icon_${s}x${s}.png;
#   rsvg-convert -w $((s*2)) -h $((s*2)) Resources/AppIcon.svg -o /tmp/AppIcon.iconset/icon_${s}x${s}@2x.png; done && iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# LSUIElement: menu bar only, no Dock icon. No sandbox: it blocks process
# inspection and signals.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MemBar</string>
  <key>CFBundleExecutable</key><string>MemBar</string>
  <key>CFBundleIdentifier</key><string>com.huetic.membar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.huetic.membar</string>
    <key>CFBundleURLSchemes</key><array><string>appmem</string></array>
  </dict></array>
</dict>
</plist>
PLIST

if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP"  # ad hoc: runs only on this Mac, or after "Open Anyway"
fi
echo "built: $APP"
