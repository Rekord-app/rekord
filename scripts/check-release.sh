#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "--toolchain" ]]; then
    sdk="$(xcrun --sdk macosx --show-sdk-version)"
    [[ "${sdk%%.*}" -ge 26 ]] || { echo "Build benötigt macOS SDK 26+ (Xcode 26+), ausgewählt: $sdk. xcode-select prüfen." >&2; exit 1; }
    exit 0
fi
app="${1:?Usage: check-release.sh <Rekord.app> | --toolchain}"
codesign --verify --deep --strict "$app"
for binary in "$app" "$app/Contents/MacOS/rekord-mcp"; do
    signature="$(codesign -dv --verbose=4 "$binary" 2>&1)"
    [[ "$signature" == *'Authority=Developer ID Application:'* && "$signature" == *'runtime'* && "$signature" == *'Timestamp='* ]] || { echo "Keine gültige Distribution-Signatur: $binary" >&2; exit 1; }
done
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
