#!/bin/bash
# Package and publish are separate actions. Distribution never falls back to local signing.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
repo="${PUBLIC_REPO:-Rekord-app/rekord}"
mode="${1:---package}"
output="${2:?Usage: release.sh --package <new-output-dir> | --publish <reviewed-output-dir>}"
work="$(mktemp -d)"
trap 'git -C "$root" worktree remove --force "$work/src" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
if [[ "$mode" == "--package" ]]; then
    : "${PUBLIC_COMMIT:?Exakten veröffentlichten Commit als PUBLIC_COMMIT setzen.}"
    : "${REKORD_SIGNING_IDENTITY:?Developer ID Application fehlt.}"
    : "${REKORD_NOTARY_PROFILE:?Notarytool-Keychain-Profil fehlt.}"
    [[ "$PUBLIC_COMMIT" =~ ^[0-9a-f]{40}$ && ! -e "$output" ]] || { echo "Vollen Commit und neues Ausgabe-Verzeichnis angeben." >&2; exit 1; }
    [[ -z "$(git -C "$root" status --porcelain)" ]] || { echo "Änderungen zuerst committen; Release verlangt einen sauberen Stand." >&2; exit 1; }
    private_commit="$(git -C "$root" rev-parse HEAD)"
    "$root/scripts/export-public.sh" "$private_commit" "$work/export"
    git clone -q "https://github.com/$repo.git" "$work/public"
    git -C "$work/public" checkout -q --detach "$PUBLIC_COMMIT"
    diff -qr --exclude=.git "$work/export" "$work/public" || { echo "Öffentlicher Quellstand passt nicht zum Build." >&2; exit 1; }
    public_tree="$(git -C "$work/public" rev-parse HEAD^{tree})"
    git -C "$root" worktree add -q --detach "$work/src" "$private_commit"
    REKORD_SIGNING=distribution REKORD_APP_DIR="$work" "$work/src/scripts/build-app.sh"
    "$work/src/scripts/notarize.sh" "$work/Rekord.app"
    mkdir -p "$output"
    # Only package after stapling; the manifest hashes the exact delivered ZIP.
    ditto -c -k --keepParent "$work/Rekord.app" "$output/Rekord.zip"
    version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$work/Rekord.app/Contents/Info.plist")"
    python3 - "$output" "$version" "$private_commit" "$PUBLIC_COMMIT" "$public_tree" "$repo" "$work/Rekord.app" <<'PY'
import datetime,hashlib,json,pathlib,subprocess,sys
out,version,private,public,tree,repo,app=sys.argv[1:]; out=pathlib.Path(out)
def command(*args): return subprocess.check_output(args,text=True).strip()
manifest=dict(app='Rekord',version=version,private_commit=private,public_commit=public,public_tree=tree,repository=repo,
    architectures=command('lipo','-archs',app+'/Contents/MacOS/Rekord'),zip_sha256=hashlib.sha256((out/'Rekord.zip').read_bytes()).hexdigest(),swift=command('swift','--version'),sdk=command('xcrun','--sdk','macosx','--show-sdk-version'),
    built=datetime.datetime.now(datetime.timezone.utc).isoformat(),notarized=True)
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
    awk -v v="## $version" 'index($0,v)==1{on=1;next} on&&/^## /{exit} on' "$root/CHANGELOG.md" > "$output/notes.md"
    cat >> "$output/notes.md" <<'NOTES'

Developer-ID-signiert und notarisiert. ZIP entpacken und Rekord.app nach Programme ziehen.
Beim Wechsel von einer lokal signierten Version können Datenschutzfreigaben und Keychain-Zugriff erneut angefragt werden. Aufnahmen bleiben erhalten.
NOTES
    echo "Paket vorbereitet: $output. Prüfen und separat mit --publish veröffentlichen."
elif [[ "$mode" == "--publish" ]]; then
    python3 - "$output" "$repo" <<'PY'
import hashlib,json,pathlib,re,sys
out=pathlib.Path(sys.argv[1]); m=json.loads((out/'manifest.json').read_text())
assert m['repository']==sys.argv[2] and m['notarized'] is True
assert re.fullmatch(r'[0-9a-f]{40}',m['public_commit']) and re.fullmatch(r'\d+\.\d+\.\d+',m['version'])
assert hashlib.sha256((out/'Rekord.zip').read_bytes()).hexdigest()==m['zip_sha256'],'ZIP changed after review'
PY
    public_commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["public_commit"])' "$output/manifest.json")"
    version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$output/manifest.json")"
    git clone -q "https://github.com/$repo.git" "$work/public"
    [[ "$(git -C "$work/public" rev-parse "$public_commit^{tree}")" == "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["public_tree"])' "$output/manifest.json")" ]] || exit 1
    ditto -x -k "$output/Rekord.zip" "$work/unpacked"
    "$root/scripts/check-release.sh" "$work/unpacked/Rekord.app"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$work/unpacked/Rekord.app/Contents/Info.plist")" == "$version" ]] || exit 1
    gh release create "v$version" "$output/Rekord.zip" "$output/manifest.json" --repo "$repo" --target "$public_commit" --title "Rekord $version" --notes-file "$output/notes.md" --latest
else
    echo "Nur --package oder --publish unterstützt." >&2; exit 1
fi
