#!/usr/bin/env python3
import concurrent.futures, json, subprocess, sys, hashlib, datetime, platform
from pathlib import Path
root=Path(__file__).parent
cases=json.loads((root/'eval-cases.json').read_text())
def run(case):
    folder=root/'runs'/case['id']; folder.mkdir(parents=True,exist_ok=True)
    (folder/'input.json').write_text(json.dumps(case['input'],ensure_ascii=False))
    p=subprocess.run([sys.executable,str(root/'customer_update.py'),str(folder/'input.json'),str(folder/'output.json')],capture_output=True,text=True)
    return {'id':case['id'],'exit_code':p.returncode,'output':json.loads((folder/'output.json').read_text()),'stderr':p.stderr,'script_sha256':hashlib.sha256((root/'customer_update.py').read_bytes()).hexdigest(),'python':platform.python_version(),'finished_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool: runs=list(pool.map(run,cases))
(root/'eval-runs.json').write_text(json.dumps(runs,ensure_ascii=False,indent=2)+'\n')
assert len(runs)==10 and all(x['exit_code']==0 for x in runs)
print('10 echte Skriptläufe in Batches mit höchstens 3 parallelen Prozessen; keine Netzwerkzugriffe.')
