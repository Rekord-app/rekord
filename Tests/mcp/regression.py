#!/usr/bin/env python3
"""MCP-server regressions from the review of 15.10.2026 (F1, F5, F8), against the real rekord-mcp binary.
Usage: Tests/mcp/regression.py <rekord-mcp> <fixture.rekord>   (fixture: swift run RecorderCoreTests --make-demo <dir>)
Only synthetic media in a temporary copy is touched."""
import hashlib, json, os, shutil, subprocess, sys, tempfile, time

binary, source = sys.argv[1], sys.argv[2]
work = tempfile.mkdtemp(prefix="rekord-mcp-")
project = os.path.join(work, "fixture.rekord")
shutil.copytree(source, project)
inventory = os.path.join(work, "Inventur")
os.makedirs(os.path.join(inventory,"2026-10-14"))
process = dict(id="p-fixture", name="Kunden-Update", description="Fake-Projekt", trigger="Wöchentlich", steps=["Status lesen", "Entwurf speichern"], apps=["Mail"], inputs=["Status"], outputs=["Entwurf"], occurrences=["b-fixture"], minutesPerWeek=60, timesPerWeek=5, euroPerMonth=216.67, automatable="ja", method="claudeCode", apiStatus="prüfen", effort="S", openQuestions=[], successCriteria=["Nur Fakten"], examples=["b-fixture"])
json.dump(dict(schema="rekord.processes",schemaVersion=1,updatedAt="2026-10-14T12:00:00Z",days=["2026-10-14"],hourlyRate=50,processes=[process],rejectedNames=[]),open(os.path.join(inventory,"prozesse.json"),"w"))
block=dict(id="b-fixture",start="2026-10-14T10:00:00Z",end="2026-10-14T10:12:00Z",apps=["Mail"],hosts=[],title="Kunden-Update",activity="Schreiben",object="Projekt",goal="Informieren",tools=[],unclear=False,question="",sampleRange=[0],activeSeconds=720,summarized=True)
json.dump([block],open(os.path.join(inventory,"2026-10-14","blocks.json"),"w"))
env = dict(os.environ, REKORD_INVENTORY_ROOT=inventory)
proc = subprocess.Popen([binary], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
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
# Inventory: four real tool contracts, no raw text on day, strict malformed inputs.
for name,args in [("inventory_status",{}),("list_processes",{}),("list_processes",{"min_euro":100,"automatable":"ja","query":"Update"}),("get_process",{"process":"p-fixture"}),("get_process",{"process":"Kunden-Update","include_snapshots":True}),("get_inventory_day",{"date":"2026-10-14"})]:
    result=tool(name,**args); check(not result.get("isError"),f"{name} valid: {result}")
result=tool("get_process",process="p-fixture")
check("snapshots" not in json.loads(result["content"][0]["text"]), "snapshots must be opt-in")
for name,args in [("list_processes",{"min_euro":v}) for v in [True,"10",-1,1e100,None]] + [("list_processes",{"automatable":1}),("list_processes",{"automatable":"yes"}),("list_processes",{"query":42}),("get_process",{"process":"missing"}),("get_process",{"process":42}),("get_process",{"process":"p-fixture","include_snapshots":1}),("get_inventory_day",{"date":"2026-02-30"}),("get_inventory_day",{"date":"../private"}),("get_inventory_day",{"date":10})]:
    check(tool(name,**args).get("isError"),f"inventory invalid: {name} {args}")
print("PASS: MCP inventory (6 valid calls, 14 malformed inputs, opt-in snapshot paths)")
proc.stdin.close(); proc.wait(5)
shutil.rmtree(work)
print("PASS: MCP regressions – no export onto originals (6 paths), no silent overwrite, numeric input errors, server survives, external edits kept")
