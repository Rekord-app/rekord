#!/bin/bash
# Builds Rekord from this checkout, installs it to ~/Applications, registers the MCP server for Claude Code
# (if installed) and starts the app. Safe to run again: it replaces the installed build.
# Also migrates an installation from before the rename (Focus Recorder.app, MCP "focus-recorder").
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${REKORD_APP_DIR:-${FOCUS_APP_DIR:-$HOME/Applications}}"
APP="$APP_DIR/Rekord.app"
LEGACY_APP="$APP_DIR/Focus Recorder.app"

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    echo "Swift fehlt. Installiere die Xcode Command Line Tools: xcode-select --install"
    echo "Danach dieses Skript erneut starten."
    exit 1
fi

"$PROJECT_DIR/scripts/check-release.sh" --toolchain

# A running app keeps the old binary; quit it gracefully (it refuses while recording or exporting).
quit_app() {
    local name="$1" process="$2"
    pgrep -x "$process" >/dev/null || return 0
    osascript -e "quit app \"$name\"" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -x "$process" >/dev/null || return 0; sleep 0.5; done
    echo "$name läuft noch (Aufnahme oder Export?). Bitte beenden und erneut starten."
    exit 1
}
quit_app "Rekord" "Rekord"
quit_app "Focus Recorder" "FocusRecorder"

"$PROJECT_DIR/scripts/build-app.sh"

# One app bundle only: the bundle from before the rename shares the identifier and would confuse macOS.
if [[ -d "$LEGACY_APP" ]]; then rm -rf "$LEGACY_APP"; echo "Alte App „Focus Recorder“ entfernt (Aufnahmen bleiben erhalten)."; fi

if command -v claude >/dev/null 2>&1; then
    if claude mcp get focus-recorder >/dev/null 2>&1; then claude mcp remove --scope user focus-recorder >/dev/null 2>&1 || true; fi
    if ! claude mcp get rekord >/dev/null 2>&1; then
        claude mcp add --scope user rekord -- "$APP/Contents/MacOS/rekord-mcp" >/dev/null
        echo "MCP-Server für Claude Code registriert (rekord)."
    fi
else
    echo "Claude Code nicht gefunden – MCP-Anbindung übersprungen (siehe ANLEITUNG.md)."
fi

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "Rekord $version installiert: $APP"
open "$APP"
