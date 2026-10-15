#!/bin/bash
set -euo pipefail
app="${1:?Usage: notarize.sh <Rekord.app>}"
: "${REKORD_NOTARY_PROFILE:?Keychain-Profil für notarytool fehlt (REKORD_NOTARY_PROFILE). Keine Passwörter als Argumente verwenden.}"
codesign --verify --deep --strict "$app"
signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
[[ "$signature" == *'Authority=Developer ID Application:'* && "$signature" == *'runtime'* ]] || { echo "Notarisierung benötigt Developer ID und Hardened Runtime." >&2; exit 1; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
ditto -c -k --keepParent "$app" "$work/submit.zip"
xcrun notarytool submit "$work/submit.zip" --keychain-profile "$REKORD_NOTARY_PROFILE" --wait --output-format json > "$work/result.json"
python3 - "$work/result.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted': raise SystemExit('Notarisierung nicht akzeptiert. Submission-ID: '+str(result.get('id')))
print('Notarisierung akzeptiert: '+result['id'])
PY
xcrun stapler staple "$app"
"$(dirname "$0")/check-release.sh" "$app"
