#!/bin/bash
# Publishes the current commit to the public repository (default Rekord-app/rekord) with its own, fresh history.
# Private working material never leaves this repo: the development log, deployment details of our server and the
# analyses of other products are removed, and the export is checked for infrastructure details before pushing.
# Usage: ./scripts/publish-public.sh            (needs gh with push access to the public repo)
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC_REPO="${PUBLIC_REPO:-Rekord-app/rekord}"
PRIVATE_PATHS=(PLAN.md AGENTS.md CLAUDE.md .claude share-service/DEPLOYMENT.md docs/design-review-*.md docs/*reverse-engineering*.md docs/screen-studio-*.md)
FORBIDDEN='srv1804476|os\.nikitasapunov\.de|Hostinger|reverse-engineering\.md|sk-ant-[A-Za-z0-9_-]{10}|ghp_[A-Za-z0-9]{20}'
cd "$PROJECT_DIR"
commit="$(git rev-parse HEAD)"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir "$work/tree"
git archive "$commit" | tar -x -C "$work/tree"
(cd "$work/tree" && for pattern in "${PRIVATE_PATHS[@]}"; do rm -rf $pattern; done)
if find "$work/tree" -iname '*reverse-engineering*' | grep -q .; then echo "Abbruch: Analyse-Dokument im Export."; exit 1; fi
if grep -rIlE --exclude=publish-public.sh "$FORBIDDEN" "$work/tree"; then echo "Abbruch: Server-Interna oder Schlüssel in den oben genannten Dateien."; exit 1; fi
git clone -q "https://github.com/$PUBLIC_REPO.git" "$work/public" 2>/dev/null || { mkdir "$work/public"; git -C "$work/public" init -q -b main; git -C "$work/public" remote add origin "https://github.com/$PUBLIC_REPO.git"; }
rsync -a --delete --exclude .git "$work/tree/" "$work/public/"
cd "$work/public"
git add -A
if git diff --cached --quiet; then echo "Öffentliches Repo ist schon auf diesem Stand."; exit 0; fi
git commit -q -m "Rekord $version" -m "Exported from the development repository (${commit:0:7})."
git push -q origin HEAD:main
echo "Veröffentlicht: https://github.com/$PUBLIC_REPO (Rekord $version, $(git rev-parse --short HEAD))"
