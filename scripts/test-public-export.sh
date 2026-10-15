#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
"$root/scripts/export-public.sh" "${1:-HEAD}" "$work/tree"
python3 - "$work/tree" <<'PY'
from pathlib import Path
from urllib.parse import unquote
import re,sys
root=Path(sys.argv[1]); errors=[]
for p in root.rglob('*.md'):
    text=re.sub(r'```.*?```','',p.read_text(),flags=re.S)
    links=re.findall(r'!?\[[^\]]*\]\(([^\s)]+)(?:\s+[^)]*)?\)',text)+re.findall(r'(?:src|href)="([^"]+)"',text)
    for link in links:
        if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:',link) or link.startswith(('#','/')): continue
        target=unquote(link.split('#')[0].split('?')[0])
        if target and not (p.parent/target).exists(): errors.append(f'{p.relative_to(root)} → {link}')
if errors: raise SystemExit('Broken public links:\n'+'\n'.join(errors))
print('PASS public exclusions and local documentation links')
PY
