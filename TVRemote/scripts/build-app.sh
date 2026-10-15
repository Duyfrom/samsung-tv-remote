#!/bin/bash
# Builds build/TV Remote.app (menu bar app) and build/tvctl, ad-hoc signed.
#   scripts/build-app.sh            build
#   scripts/build-app.sh --install  also copy the app to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product TVRemote
swift build -c release --product tvctl
swift build -c release --product tvmcp
BIN="$(swift build -c release --show-bin-path)"

APP="build/TV Remote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TVRemote" "$APP/Contents/MacOS/TVRemote"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/tvmcp" "$APP/Contents/MacOS/tvmcp" # MCP server, run by Claude Code from inside the bundle
cp "$BIN/tvctl" build/tvctl
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/tvmcp"
codesign --force --sign - --timestamp=none "$APP"
codesign --force --sign - --timestamp=none build/tvctl
echo "Built $APP and build/tvctl"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x TVRemote 2>/dev/null || true
  rm -rf "/Applications/TV Remote.app"
  cp -R "$APP" /Applications/
  open "/Applications/TV Remote.app"
  echo "Installed to /Applications and launched"
fi
