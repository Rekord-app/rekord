#!/bin/bash
# Builds Rekord, packs it as Rekord.zip and publishes it as a GitHub release (tag v<version>).
# The zip is signed with the same local identity as every release, so colleagues keep their macOS grants on update.
# Usage: ./scripts/release.sh            (needs gh, logged in with access to Rekord-app/rekord)
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${PUBLIC_REPO:-Rekord-app/rekord}"   # releases live in the public repo (see publish-public.sh)
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
tag="v$version"
cd "$PROJECT_DIR"
if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then echo "Release $tag gibt es schon. Version in Resources/Info.plist erhöhen."; exit 1; fi
commit="$(git rev-parse HEAD)"
git fetch -q origin
git merge-base --is-ancestor "$commit" origin/main || { echo "HEAD ist nicht auf GitHub (origin/main). Erst pushen."; exit 1; }
# The release must be exactly this commit: build from a clean checkout of it, never from the working tree
# (uncommitted or untracked files would end up in the download without being in the tagged source).
if [[ -n "$(git status --porcelain --untracked-files=normal -- Sources Resources Package.swift scripts)" ]]; then
    echo "Hinweis: Arbeitsbaum hat uncommittete Änderungen – sie sind NICHT im Release (gebaut wird $commit)."
fi

work="$(mktemp -d)"; trap 'git -C "$PROJECT_DIR" worktree remove --force "$work/src" >/dev/null 2>&1; rm -rf "$work"' EXIT
git worktree add -q --detach "$work/src" "$commit"
REKORD_APP_DIR="$work" "$work/src/scripts/build-app.sh" >/dev/null
codesign --verify --strict "$work/Rekord.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$work/Rekord.app/Contents/Info.plist")" == "$version" ]] || { echo "Version im Build passt nicht."; exit 1; }
# ditto keeps the bundle structure and signature intact (zip would not).
ditto -c -k --keepParent "$work/Rekord.app" "$work/Rekord.zip"
sha="$(shasum -a 256 "$work/Rekord.zip" | cut -d' ' -f1)"
cat > "$work/manifest.json" <<MANIFEST
{"app":"Rekord","version":"$version","commit":"$commit","architectures":"$(lipo -archs "$work/Rekord.app/Contents/MacOS/Rekord")","zip_sha256":"$sha","built":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
MANIFEST

# Release notes: the CHANGELOG section of this version plus the install steps.
notes="$work/notes.md"
awk -v v="## $version" 'index($0,v)==1{on=1;next} on&&/^## /{exit} on' CHANGELOG.md > "$notes"
cat >> "$notes" <<'NOTES'

---
**Installieren:** `Rekord.zip` herunterladen, entpacken, `Rekord.app` in den Ordner **Programme** ziehen, öffnen. Beim ersten Mal: Systemeinstellungen → Datenschutz & Sicherheit → **Trotzdem öffnen**. Details: [ANLEITUNG.md](https://github.com/Rekord-app/rekord/blob/main/ANLEITUNG.md)
**Updaten:** Rekord beenden, neue `Rekord.app` über die alte ziehen (Ersetzen). Freigaben und Aufnahmen bleiben.
NOTES
echo "" >> "$notes"; echo "Build: Commit \`$commit\` · SHA-256 der ZIP: \`$sha\` (siehe manifest.json)" >> "$notes"
# The tag points at the public commit with the same content (publish-public.sh must have run for this commit).
public_commit="$(gh api "repos/$REPO/commits/main" --jq .sha)"
gh release create "$tag" "$work/Rekord.zip" "$work/manifest.json" --repo "$REPO" --target "$public_commit" --title "Rekord $version" --notes-file "$notes" --latest
echo "Veröffentlicht: https://github.com/$REPO/releases/tag/$tag"
