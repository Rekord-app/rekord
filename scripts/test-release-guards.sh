#!/bin/bash
# Exercise the real publication guards against a disposable local remote, never GitHub.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
"$root/scripts/export-public.sh" HEAD "$work/tree" >/dev/null
git -C "$work/tree" init -q -b main
git -C "$work/tree" config user.name 'Synthetic Test'
git -C "$work/tree" config user.email 'test@example.invalid'
git -C "$work/tree" add .
git -C "$work/tree" commit -qm 'Synthetic public source' -m "Exported from the development repository ($(git -C "$root" rev-parse HEAD))."
git clone -q --bare "$work/tree" "$work/remote.git"
export PUBLIC_REPO='synthetic-rekord-test/never-publish'
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$work/remote.git.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/$PUBLIC_REPO.git"
head="$(git -C "$work/tree" rev-parse HEAD)"
export EXPECTED_PUBLIC_COMMIT='0000000000000000000000000000000000000000'
if "$root/scripts/publish-public.sh" > "$work/result" 2>&1; then echo 'FAIL stale expected HEAD accepted'; exit 1; fi
grep -q 'neue Commits' "$work/result"
# A change with a forged export footer must also be preserved, not overwritten.
printf '\nSynthetic community contribution\n' >> "$work/tree/README.md"
git -C "$work/tree" add .
git -C "$work/tree" commit -qm 'Community edit' -m "Exported from the development repository ($(git -C "$root" rev-parse HEAD))."
git -C "$work/tree" push -q "$work/remote.git" HEAD:main
export EXPECTED_PUBLIC_COMMIT="$(git -C "$work/tree" rev-parse HEAD)"
if "$root/scripts/publish-public.sh" > "$work/result" 2>&1; then echo 'FAIL community edit overwritten'; exit 1; fi
grep -q 'weicht ab' "$work/result"
[[ "$(git --git-dir="$work/remote.git" rev-parse HEAD)" == "$EXPECTED_PUBLIC_COMMIT" ]]
# Wrong public content must fail before any signing/notarization can happen.
export PUBLIC_COMMIT="$EXPECTED_PUBLIC_COMMIT" REKORD_SIGNING_IDENTITY='test-only-invalid' REKORD_NOTARY_PROFILE='test-only-invalid'
if "$root/scripts/release.sh" --package "$work/package" > "$work/result" 2>&1; then echo 'FAIL drifted release accepted'; exit 1; fi
grep -q 'Quellstand passt nicht' "$work/result"
[[ ! -e "$work/package/Rekord.zip" ]]
# Legacy exported publishers contained their own literal denylist. They must be
# comparable without exempting an outgoing candidate or any community edits.
git clone -q --shared "$root" "$work/legacy-dev"
git -C "$work/legacy-dev" config user.name 'Synthetic Test'
git -C "$work/legacy-dev" config user.email 'test@example.invalid'
candidate="$(git -C "$work/legacy-dev" rev-parse HEAD)"
printf '\n# Historical denylist sentinel: %s%s\n' Host inger >> "$work/legacy-dev/scripts/publish-public.sh"
git -C "$work/legacy-dev" add scripts/publish-public.sh
git -C "$work/legacy-dev" commit -qm 'Synthetic historical publisher'
legacy="$(git -C "$work/legacy-dev" rev-parse HEAD)"
if "$work/legacy-dev/scripts/export-public.sh" "$legacy" "$work/unsafe-candidate" > "$work/result" 2>&1; then echo 'FAIL outgoing publisher exempted from scan'; exit 1; fi
grep -q 'Privater Inhalt' "$work/result"
"$work/legacy-dev/scripts/export-public.sh" "$legacy" "$work/legacy-tree" --reproduce >/dev/null
git -C "$work/legacy-tree" init -q -b main
git -C "$work/legacy-tree" config user.name 'Synthetic Test'
git -C "$work/legacy-tree" config user.email 'test@example.invalid'
git -C "$work/legacy-tree" add .
git -C "$work/legacy-tree" commit -qm 'Synthetic legacy public source' -m "Exported from the development repository (${legacy:0:7})."
git clone -q --bare "$work/legacy-tree" "$work/legacy-remote.git"
git -C "$work/legacy-dev" checkout -q --detach "$candidate"
"$work/legacy-dev/scripts/export-public.sh" "$candidate" "$work/legacy-expected" >/dev/null
export EXPECTED_PUBLIC_COMMIT="$(git -C "$work/legacy-tree" rev-parse HEAD)"
export GIT_CONFIG_KEY_0="url.file://$work/legacy-remote.git.insteadOf"
"$work/legacy-dev/scripts/publish-public.sh" > "$work/result" 2>&1
[[ "$(git --git-dir="$work/legacy-remote.git" rev-parse HEAD)" != "$EXPECTED_PUBLIC_COMMIT" ]]
git clone -q "$work/legacy-remote.git" "$work/legacy-result"
diff -qr --exclude=.git "$work/legacy-expected" "$work/legacy-result"
echo 'PASS stale HEAD, community edit and source/build drift blocked; legacy baseline migrates and outgoing scan stays strict'
