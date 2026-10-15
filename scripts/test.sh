#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export REKORD_TEST_ARTIFACTS="${REKORD_TEST_ARTIFACTS:-$PROJECT_DIR/build/qa}"
if [[ "${1:-}" == "--mcp" ]]; then
    # MCP-server regressions on a synthetic fixture (review 15.10.2026: F1, F5, F8).
    swift build --package-path "$PROJECT_DIR" --product rekord-mcp >/dev/null
    fixture="$(mktemp -d)/demo.rekord"
    swift run --package-path "$PROJECT_DIR" RecorderCoreTests --make-demo "$fixture" >/dev/null
    python3 "$PROJECT_DIR/Tests/mcp/regression.py" "$(swift build --package-path "$PROJECT_DIR" --show-bin-path)/rekord-mcp" "$fixture"
    rm -rf "$(dirname "$fixture")"
    exit 0
fi
swift run --package-path "$PROJECT_DIR" RecorderCoreTests "$@"
