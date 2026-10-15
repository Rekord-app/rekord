#!/bin/bash
# Pure export of one immutable Git commit. Never pushes or changes a checkout.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
commit="$(git -C "$root" rev-parse "${1:-HEAD}^{commit}")"
destination="${2:?Usage: export-public.sh <commit> <new-directory> [--reproduce]}"
# --reproduce rebuilds an export that is already public (to compare it file by file); it skips the content check,
# which only guards what is about to be published.
check="yes"; [[ "${3:-}" == "--reproduce" ]] && check="no"
[[ ! -e "$destination" ]] || { echo "Export-Ziel muss neu sein." >&2; exit 1; }
mkdir -p "$destination"
git -C "$root" archive "$commit" | tar -x -C "$destination"
python3 - "$destination" "$check" <<'PY'
from pathlib import Path
import hashlib,re,shutil,sys
root=Path(sys.argv[1]); check=sys.argv[2] == 'yes'
# Private infrastructure names (server host, internal domain, provider) as SHA-256 of the lower-case word,
# so the guard itself never publishes them. Generic key formats stay readable.
PRIVATE={'f0c49c0cf8ad8596e956dc2f3b2d9b5f0fa333728bb7670f315aeef669d3241a','6f7159167cd1842481cc4e50ccf7ac75bddff5ec2fc32253962591d39497a002','fefaa42da40ecf93662a6f2852c1d4315ff7593420cd3538f6eaf6afee38f1a2'}
def private_word(data):
    for word in set(re.findall(rb'[a-z0-9][a-z0-9.-]*',data.lower())):
        parts=word.strip(b'.-').split(b'.')
        if any(hashlib.sha256(b'.'.join(parts[i:])).hexdigest() in PRIVATE for i in range(len(parts))): return True
    return False
for pattern in ('PLAN.md','AGENTS.md','CLAUDE.md','.claude','share-service/DEPLOYMENT.md','docs/design-review-*.md','docs/*reverse-engineering*.md','docs/screen-studio-*.md'):
    for path in root.glob(pattern):
        if path.is_dir(): shutil.rmtree(path)
        else: path.unlink()
for path in root.rglob('*'):
    if path.is_symlink(): raise SystemExit('Symlinks im öffentlichen Export prüfen: '+str(path.relative_to(root)))
    if not path.is_file(): continue
    if 'reverse-engineering' in path.name or path.name == '.env': raise SystemExit('Privater Pfad im Export: '+str(path.relative_to(root)))
    if not check: continue
    data=path.read_bytes()
    if re.search(rb'sk-ant-[A-Za-z0-9_-]{10}|ghp_[A-Za-z0-9]{20}',data) or private_word(data):
        raise SystemExit('Privater Inhalt im Export: '+str(path.relative_to(root)))
print('Export geprüft: '+str(root))
PY
