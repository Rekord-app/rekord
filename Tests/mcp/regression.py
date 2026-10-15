#!/usr/bin/env python3
"""MCP-server regressions from the review of 15.10.2026 (F1, F5, F8), against the real rekord-mcp binary.
Usage: Tests/mcp/regression.py <rekord-mcp> <fixture.rekord>   (fixture: swift run RecorderCoreTests --make-demo <dir>)
Only synthetic media in a temporary copy is touched."""
import hashlib, json, os, shutil, subprocess, sys, tempfile, time

binary, source = sys.argv[1], sys.argv[2]
work = tempfile.mkdtemp(prefix="rekord-mcp-")
project = os.path.join(work, "fixture.rekord")
shutil.copytree(source, project)
proc = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
counter = 0
def rpc(method, params=None):
    global counter; counter += 1
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": counter, "method": method, "params": params or {}}) + "\n"); proc.stdin.flush()
    line = proc.stdout.readline()
    if not line: raise SystemExit(f"FAIL: server died during {method} {params}")
    return json.loads(line)
def tool(name, **args): return rpc("tools/call", {"name": name, "arguments": args})["result"]
def digest(path): return hashlib.sha256(open(path, "rb").read()).hexdigest()
def check(condition, message):
    if not condition: raise SystemExit("FAIL: " + message)

rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "regression", "version": "1"}})
originals = {name: digest(os.path.join(project, name)) for name in os.listdir(project) if os.path.isfile(os.path.join(project, name))}
# F1: export must never land on recording data, however the path is written.
os.symlink(os.path.join(project, "screen.mov"), os.path.join(work, "alias.mp4"))
for output in ["screen.mov", "project.json", "camera.mov", "../fixture.rekord/screen.mov", "x.mp4"]:
    result = tool("export_mp4", recording=project, output=os.path.join(project, output), height=720, fps=30)
    check(result.get("isError"), f"export onto {output} must fail")
result = tool("export_mp4", recording=project, output=os.path.join(work, "alias.mp4"), height=720, fps=30, overwrite=True)
check(result.get("isError"), "export through a symlink to screen.mov must fail")
check(all(digest(os.path.join(project, n)) == h for n, h in originals.items()), "originals changed")
# Existing files are only replaced on request.
open(os.path.join(work, "existing.mp4"), "w").write("keep")
check(tool("export_mp4", recording=project, output=os.path.join(work, "existing.mp4"), height=720, fps=30).get("isError"), "silent overwrite")
check(not tool("export_mp4", recording=project, output=os.path.join(work, "ok.mp4"), height=720, fps=30).get("isError"), "valid export failed")
# F8: absurd numbers are tool errors, the server keeps running.
for value in [1e100, -1, 1.5, 99999999999]:
    check(tool("render_frame", recording=project, time_s=0.5, height=value).get("isError"), f"render_frame height {value} must be an error")
    check(tool("export_mp4", recording=project, output=os.path.join(work, "n.mp4"), height=value).get("isError"), f"export height {value} must be an error")
check(tool("list_meetings", min_interest=1e100).get("isError"), "list_meetings min_interest 1e100 must be an error")
check(not tool("render_frame", recording=project, time_s=0.5, height=360).get("isError"), "server must still render after bad input")
# F5: a change made elsewhere between get and save is reported, not overwritten.
tool("get_recording", recording=project)
path = os.path.join(project, "project.json")
data = json.load(open(path)); data["name"] = "external change"; time.sleep(0.02)
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
check(not tool("update_look", recording=project, padding=0.1).get("isError"), "update_look after an external change failed")
saved = json.load(open(path))
check(saved["name"] == "external change" and abs(saved["style"]["padding"] - 0.1) < 1e-9, "external change lost by a later MCP edit")
proc.stdin.close(); proc.wait(5)
shutil.rmtree(work)
print("PASS: MCP regressions – no export onto originals (6 paths), no silent overwrite, numeric input errors, server survives, external edits kept")
