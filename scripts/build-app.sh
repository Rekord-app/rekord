#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
swift build --package-path "$PROJECT_DIR" -c "$CONFIG" --product Rekord
swift build --package-path "$PROJECT_DIR" -c "$CONFIG" --product rekord-mcp
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" -c "$CONFIG" --show-bin-path)"
# Application bundles in iCloud Documents gain FinderInfo attributes after signing.
# Keep the runnable bundle outside the synced source tree.
APP_DIR="${REKORD_APP_DIR:-${FOCUS_APP_DIR:-$HOME/Applications}}"
APP="$APP_DIR/Rekord.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
rm -f "$APP/Contents/MacOS/FocusRecorder" "$APP/Contents/MacOS/focus-recorder-mcp"   # names before the rename
cp "$BIN_DIR/Rekord" "$APP/Contents/MacOS/Rekord"
# MCP server for Claude Code (stdio); signed as a nested executable below.
cp "$BIN_DIR/rekord-mcp" "$APP/Contents/MacOS/rekord-mcp"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
xattr -cr "$APP"
# Stable local identity keeps macOS privacy grants across rebuilds (see signing-identity.sh).
# REKORD_SIGNING=adhoc restores the previous per-build ad-hoc signature.
source "$PROJECT_DIR/scripts/signing-identity.sh"
focus_sign "$APP" "$PROJECT_DIR/Resources/FocusRecorder.entitlements"
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
echo "Built: $APP"
