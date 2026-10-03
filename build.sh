#!/bin/bash
# Makes build/AppMem.app around the SwiftPM binary (same pattern as ~/projects/Search).
#
#   ./build.sh           release build, ad-hoc signed: runs on this Mac
#   ./build.sh debug     debug build
#
#   open build/AppMem.app                            run it (menu bar only, no Dock icon)
#   build/AppMem.app/Contents/MacOS/AppMem --test    self-check of the pure rules
#   build/AppMem.app/Contents/MacOS/AppMem --list    groups as text, like appmem.py
#   build/AppMem.app/Contents/MacOS/AppMem --help    every flag
#   build/AppMem.app/Contents/MacOS/AppMem --json [--cpu]          groups, RAM and swap as JSON
#   build/AppMem.app/Contents/MacOS/AppMem --leftovers             one per line; exit 1 if any
#   build/AppMem.app/Contents/MacOS/AppMem --stop [NAME ...] [--dry-run]   stop leftovers
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
APP="build/AppMem.app"

swift build -c "$CONFIG"

mkdir -p "$APP/Contents/MacOS"
# Copy, then rename over the old binary: a new file, so a copy that runs is not
# changed under it, and macOS does not keep the old code signature.
cp ".build/$CONFIG/AppMem" "$APP/Contents/MacOS/AppMem.new"
mv -f "$APP/Contents/MacOS/AppMem.new" "$APP/Contents/MacOS/AppMem"

# LSUIElement: menu bar only, no Dock icon. No sandbox: it blocks process
# inspection and signals.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AppMem</string>
  <key>CFBundleExecutable</key><string>AppMem</string>
  <key>CFBundleIdentifier</key><string>com.officecommun.appmem</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built: $APP"
