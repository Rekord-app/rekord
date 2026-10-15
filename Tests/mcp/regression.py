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
support = tempfile.mkdtemp(prefix="rekord-mcp-support-")
env = dict(os.environ, REKORD_INVENTORY_ROOT=inventory, REKORD_RECORDINGS_ROOT=work, REKORD_SUPPORT_ROOT=support)
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
# Parity tools: every app feature has a tool. Only file-level paths and argument checks run here; nothing reaches the app.
names = {t["name"] for t in rpc("tools/list")["result"]["tools"]}
expected = {"list_recordings","get_recording","render_frame","update_look","edit_zooms","edit_cuts","edit_camera_layouts","rename_recording","export_mp4","recorder","share_link",
            "list_meetings","get_meeting","list_guides","get_guide","inventory_status","list_processes","get_process","get_inventory_day",
            "manage_library","manage_shares","video_offers","meeting_control","guide_control","edit_guide","inventory_control","storage","settings"}
check(expected <= names, f"missing tools: {expected - names}")
def recording(): return json.loads(tool("get_recording", recording=project)["content"][0]["text"])
def style(): return json.load(open(os.path.join(project, "project.json")))["style"]
tool("edit_cuts", recording=project, action="reset")
info = recording(); duration = info["duration_s"]
check(all("id" in s for s in info["sections_list"]), "sections need ids")
r = tool("edit_cuts", recording=project, action="split", at_s=duration/2); check(not r.get("isError"), f"split failed: {r} {info['sections_list']} {duration}")
sections = recording()["sections_list"]; check(len(sections) == 2, f"split must give two sections: {sections}")
check(not tool("edit_cuts", recording=project, action="update_section", id=sections[1]["id"], from_s=sections[1]["start_s"]+0.2).get("isError"), "update_section failed")
check(abs(recording()["sections_list"][1]["start_s"] - (sections[1]["start_s"]+0.2)) < 0.02, "update_section did not move the start")
check(not tool("edit_cuts", recording=project, action="delete_section", id=sections[1]["id"]).get("isError"), "delete_section failed")
last = recording()["sections_list"]; check(len(last) == 1, "one section left")
check(tool("edit_cuts", recording=project, action="delete_section", id=last[0]["id"]).get("isError"), "the last section must stay")
check(tool("edit_cuts", recording=project, action="split", at_s=0).get("isError"), "split at the edge must fail")
check(tool("edit_cuts", recording=project, action="delete_section", id="nope").get("isError"), "unknown section id must fail")
tool("edit_cuts", recording=project, action="reset")
check(not tool("update_look", recording=project, background_gradient={"start": "#102030", "end": "#F0A050", "angle": 120}).get("isError"), "gradient failed")
check(style()["backdrop"]["kind"] == "gradient" and style()["backdrop"]["angle"] == 120, "gradient not saved")
for bad in [{"click_effect": "boom"}, {"camera_shape": "star"}, {"camera_position": "mitte"}, {"camera_x": 2}, {"background_gradient": {"start": "#12"}}, {"background_blur": 0.01}, {"background_image": os.path.join(work, "missing.png")}]:
    check(tool("update_look", recording=project, **bad).get("isError"), f"update_look {bad} must fail")
check(not tool("update_look", recording=project, camera_x=0.3, camera_y=0.7).get("isError"), "camera_x/y failed")
check(abs(style()["cameraPosition"]["x"]-0.3) < 1e-9 and abs(style()["cameraPosition"]["y"]-0.7) < 1e-9, "camera position not saved")
import base64
png = os.path.join(work, "bg.png"); open(png, "wb").write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
check(not tool("update_look", recording=project, background_image=png).get("isError"), "background_image failed")
image = style()["backdrop"]["imageFile"]
check(style()["backdrop"]["kind"] == "image" and os.path.isfile(os.path.join(project, image)), "background image not copied into the project")
check(not tool("update_look", recording=project, background_blur=0.02).get("isError"), "background_blur failed")
check(not tool("render_frame", recording=project, time_s=0.5, height=240).get("isError"), "render with background image failed")
tool("edit_zooms", recording=project, action="clear")
zooms = json.loads(tool("edit_zooms", recording=project, action="add", start_s=0.2, end_s=1.0, scale=2, focus_x=0.2, focus_y=0.3)["content"][0]["text"])
check(len(zooms) == 1 and not zooms[0]["follows_cursor"], f"fixed-point zoom: {zooms}")
zooms = json.loads(tool("edit_zooms", recording=project, action="update", id=zooms[0]["id"], follows_cursor=True)["content"][0]["text"])
check(zooms[0]["follows_cursor"], "follows_cursor must switch back on")
os.makedirs(os.path.join(work, "Kunden")); os.makedirs(os.path.join(work, "Meetings"))
folders = json.loads(tool("manage_library", action="list_folders")["content"][0]["text"])
check([f["folder"] for f in folders["folders"]] == ["Kunden"] and folders["without_folder"] == 1, f"list_folders: {folders}")
check(any(r.get("folder") is None for r in json.loads(tool("list_recordings")["content"][0]["text"])), "list_recordings in the test library")
for name, args in [("manage_library", {"action": "nope"}), ("settings", {"action": "set"}), ("settings", {"action": "set", "values": {"claude_key": "x"}}),
                   ("settings", {"action": "set", "values": {"share_server": "x"}}), ("manage_shares", {"action": "set_expiry", "video_id": "x"}),
                   ("video_offers", {"action": "bogus"}), ("meeting_control", {"action": "explode"}), ("guide_control", {"action": "nope"}),
                   ("inventory_control", {"action": "team"}), ("storage", {"action": "wipe"}), ("manage_library", {"action": "trash", "confirm": True}),
                   ("manage_library", {"action": "trash", "recording": "latest", "confirm": True}), ("meeting_control", {"action": "delete", "confirm": True}),
                   ("guide_control", {"action": "delete", "confirm": True}), ("recorder", {"action": "status"})]:
    result = tool(name, **args)
    if name == "recorder": continue
    check(result.get("isError"), f"{name} {args} must be refused before reaching the app")
check(not os.listdir(os.path.join(support, "calls")) if os.path.isdir(os.path.join(support, "calls")) else True, "no call may have been sent")
print("PASS: MCP parity – 28 tools listed, sections split/update/delete by id, gradient/image/blur/fine camera, zoom follows cursor again, folders, 14 refusals before the app (incl. delete without explicit target)")
proc.stdin.close(); proc.wait(5)
shutil.rmtree(work); shutil.rmtree(support)
print("PASS: MCP regressions – no export onto originals (6 paths), no silent overwrite, numeric input errors, server survives, external edits kept")
