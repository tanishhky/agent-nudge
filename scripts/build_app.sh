#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "1. Building release binary..."
swift build -c release

BIN_PATH="$ROOT_DIR/.build/release/AgentNudge"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Error: Release binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "2. Generating AppIcon.icns..."
ICONSET_DIR="$ROOT_DIR/dist/AppIcon.iconset"
ICNS_PATH="$ROOT_DIR/dist/AppIcon.icns"
rm -rf "$ICONSET_DIR" "$ICNS_PATH"
mkdir -p "$ROOT_DIR/dist"
swift "$ROOT_DIR/scripts/generate_icon.swift" "$ICONSET_DIR"
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
rm -rf "$ICONSET_DIR"

echo "3. Assembling AgentNudge.app..."
STAGE_APP="$ROOT_DIR/dist/AgentNudge.app"
rm -rf "$STAGE_APP"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"

cp "$BIN_PATH" "$STAGE_APP/Contents/MacOS/AgentNudge"
cp "$ROOT_DIR/Resources/Info.plist" "$STAGE_APP/Contents/Info.plist"
cp "$ICNS_PATH" "$STAGE_APP/Contents/Resources/AppIcon.icns"
printf "APPL????" > "$STAGE_APP/Contents/PkgInfo"

echo "4. Installing to /Applications/AgentNudge.app..."
pkill -x AgentNudge || true
sleep 0.5
rm -rf /Applications/AgentNudge.app
cp -R "$STAGE_APP" /Applications/AgentNudge.app

echo "5. Signing /Applications/AgentNudge.app..."
codesign --force --deep --sign - --identifier com.tanishkyadav.agent-nudge /Applications/AgentNudge.app
codesign --verify --verbose /Applications/AgentNudge.app

echo "Done! Installed at /Applications/AgentNudge.app"
