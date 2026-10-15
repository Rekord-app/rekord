#!/bin/bash
# Pulls the latest version and reinstalls. Local changes are never overwritten: the pull only fast-forwards.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
before="$(git rev-parse --short HEAD)"
git pull --ff-only
after="$(git rev-parse --short HEAD)"
if [[ "$before" == "$after" ]]; then echo "Schon aktuell ($after). Installiere trotzdem neu."; else
    echo "Neu seit $before:"; git log --format='  • %s' "$before..$after"; fi
"$PROJECT_DIR/scripts/install.sh"
