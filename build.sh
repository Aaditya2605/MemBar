#!/bin/bash
# Makes build/AppMem.app around the SwiftPM binary (same pattern as ~/projects/Search).
#
#   ./build.sh           release build, ad-hoc signed: runs on this Mac
#   ./build.sh debug     debug build
#
#   open build/AppMem.app      run it (menu bar only, no Dock icon)
#                              (~/Applications/AppMem.app, the copy that runs on this Mac, is not updated)
#
#   AppMem=build/AppMem.app/Contents/MacOS/AppMem; the flags (same as $AppMem --help):
#   $AppMem --list                          groups as text, like appmem.py
#   $AppMem --json [--cpu]                  groups, RAM, swap, pressure as JSON; --cpu adds CPU %
#   $AppMem --leftovers                     one per line; exit 1 if any
#   $AppMem --stop [NAME ...] [--dry-run]   stop all or the named leftovers; not as root
#   $AppMem --test                          self-check of the pure rules (prints ok)
#   $AppMem --snapshot OUT.png [QUERY]      debug builds: the panel as a PNG; env CROWD=1 HISTORY=1
#                                           MARK=1 FIRSTRUN=1 DARK=0|1 add to it; LEGEND=1, MENUBAR=1
#                                           or INSPECT=sample|files|env draw that instead
#   $AppMem --snapshot-details OUT.png GROUP [QUERY]   debug builds: the Details window as a PNG
#   .build/debug/AppMem --drive OUTDIR      debug builds: the real app through a scripted run (about 40 s,
#                                           it takes the focus): a PNG per step, drive.log. The bare binary
#                                           only: an .app has the installed app's settings
#   $AppMem --help, -h                      every flag
#   .build/debug/AppMem --agent-test HOME LABEL   debug test hook, not in --help: Disable and enable
#                                           again a loaded com.appmem.test.* agent in HOME
#
#   open appmem://report       copy a Markdown report (also appmem://open, appmem://refresh)
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
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.officecommun.appmem</string>
    <key>CFBundleURLSchemes</key><array><string>appmem</string></array>
  </dict></array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built: $APP"
