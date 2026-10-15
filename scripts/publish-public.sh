#!/bin/bash
# Deliberate publication, only after reviewing the expected public HEAD.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
repo="${PUBLIC_REPO:-Rekord-app/rekord}"
: "${EXPECTED_PUBLIC_COMMIT:?Öffentlichen HEAD prüfen und EXPECTED_PUBLIC_COMMIT setzen.}"
commit="$(git -C "$root" rev-parse HEAD)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
"$root/scripts/export-public.sh" "$commit" "$work/tree"
git clone -q "https://github.com/$repo.git" "$work/public"
[[ "$(git -C "$work/public" rev-parse HEAD)" == "$EXPECTED_PUBLIC_COMMIT" ]] || { echo "Öffentliches Repo hat neue Commits; erst integrieren." >&2; exit 1; }
previous="$(git -C "$work/public" log -1 --format=%B | sed -nE 's/.*Exported from the development repository \(([0-9a-f]+)\).*/\1/p')"
[[ -n "$previous" ]] || { echo "Öffentlicher HEAD ist kein bekannter Export. Community-Änderungen zuerst integrieren." >&2; exit 1; }
"$root/scripts/export-public.sh" "$previous" "$work/previous" --reproduce
diff -qr --exclude=.git "$work/previous" "$work/public" || { echo "Öffentlicher Stand weicht ab. Änderungen zuerst integrieren." >&2; exit 1; }
rsync -a --delete --exclude .git "$work/tree/" "$work/public/"
git -C "$work/public" add -A
if git -C "$work/public" diff --cached --quiet; then echo "Schon veröffentlicht."; exit 0; fi
git -C "$work/public" commit -q -m "Rekord source update" -m "Exported from the development repository ($commit)."
git -C "$work/public" push origin HEAD:main
printf 'Veröffentlicht: %s\n' "$(git -C "$work/public" rev-parse HEAD)"
