import Foundation
import CryptoKit
import AVFoundation
import RecorderCore

/// Regressions for the independent review of 15.10.2026 (F1, F2, F3, F5). Media-backed checks (F1 on a real
/// export, F4 recovery) run with --integration in `testHardeningWithMedia`.
func testHardening() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rekord-hardening-\(UUID().uuidString)")
    defer { try? files.removeItem(at: root) }
    let project = root.appendingPathComponent("Take.rekord"), other = root.appendingPathComponent("Other.rekord")
    try files.createDirectory(at: project,withIntermediateDirectories: true); try files.createDirectory(at: other,withIntermediateDirectories: true)
    for name in ["screen.mov","camera.mov","microphone.m4a","project.json","background-a1.png","share.json"] { try Data(name.utf8).write(to: project.appendingPathComponent(name)) }
    try Data("x".utf8).write(to: other.appendingPathComponent("screen.mov"))
    // Aliases of originals outside the project.
    let symlink = root.appendingPathComponent("alias.mp4"), hardlink = root.appendingPathComponent("hard.mp4"), linkedFolder = root.appendingPathComponent("linked")
    try files.createSymbolicLink(at: symlink,withDestinationURL: project.appendingPathComponent("screen.mov"))
    try files.linkItem(at: project.appendingPathComponent("camera.mov"),to: hardlink)
    try files.createSymbolicLink(at: linkedFolder,withDestinationURL: project)

    // F1: every way of naming recording data is refused before anything is written.
    let refused: [URL] = [
        project.appendingPathComponent("screen.mov"),project.appendingPathComponent("camera.mov"),project.appendingPathComponent("microphone.m4a"),
        project.appendingPathComponent("project.json"),project.appendingPathComponent("background-a1.png"),project.appendingPathComponent("new.mp4"),
        project,URL(fileURLWithPath: project.path+"/../Take.rekord/screen.mov"),linkedFolder.appendingPathComponent("screen.mov"),
        symlink,hardlink,other.appendingPathComponent("screen.mov"),other.appendingPathComponent("export.mp4"),root,
    ]
    for target in refused {
        precondition((try? ExportTarget.validate(target,projectDirectory: project)) == nil,"Export target must be refused: \(target.path)")
    }
    for target in [root.appendingPathComponent("Take.mp4"),project.appendingPathComponent("share.mp4")] {
        try ExportTarget.validate(target,projectDirectory: project)
    }
    let screenText = try String(contentsOf: project.appendingPathComponent("screen.mov"),encoding: .utf8)
    precondition(screenText == "screen.mov")

    // F3: malformed commands become errors, never a trap.
    let bad = ["rekord://stop?x=1&x=2","rekord://stop?id=a&id=b","rekord://share","rekord://share?path=","rekord://share?path=relative/x.rekord",
               "rekord://share?path=/a&path=/b","rekord://launch-missiles","rekord://","rekord://start?source=everything","rekord://stop?unknown=1",
               "rekord://open?path=/"+String(repeating: "a",count: 2000),"https://share?path=/x","rekord://stop?id=../../etc"]
    for raw in bad {
        guard let url = URL(string: raw) else { continue }
        precondition((try? AppCommand.parse(url)) == nil,"Command must be rejected: \(raw)")
    }
    let share = try AppCommand.parse(URL(string: "rekord://share?path=/Users/x/Movies/Rekord/A.rekord&id=job-1")!)
    precondition(share == AppCommand(action: .share,path: URL(fileURLWithPath: "/Users/x/Movies/Rekord/A.rekord"),id: "job-1"))
    let legacy = try AppCommand.parse(URL(string: "focusrecorder://open-recorder")!), start = try AppCommand.parse(URL(string: "rekord://start?source=area-16:9")!)
    precondition(legacy.action == .open && start.source == .area169)

    // F2: a missing, moved, broken or incomplete project cannot be opened (so it can never stand in for another one).
    let broken = root.appendingPathComponent("Broken.rekord"), noScreen = root.appendingPathComponent("NoScreen.rekord")
    try files.createDirectory(at: broken,withIntermediateDirectories: true); try Data("{ broken".utf8).write(to: broken.appendingPathComponent("project.json"))
    try Data("x".utf8).write(to: broken.appendingPathComponent("screen.mov"))
    try files.createDirectory(at: noScreen,withIntermediateDirectories: true)
    try Project(name: "x",duration: 2,width: 100,height: 100).save(to: noScreen)
    for dir in [root.appendingPathComponent("does-not-exist.rekord"),broken,noScreen] {
        precondition((try? Project.loadForEditing(from: dir)) == nil,"Must not open: \(dir.lastPathComponent)")
    }

    // F5: an edit started from an old version can't silently replace a newer one; update() merges both changes.
    let shared = root.appendingPathComponent("Shared.rekord")
    try files.createDirectory(at: shared,withIntermediateDirectories: true); try Data("m".utf8).write(to: shared.appendingPathComponent("screen.mov"))
    var base = Project(name: "before",duration: 4,width: 100,height: 100); try base.save(to: shared)
    let seen = ProjectVersion.current(shared)
    Thread.sleep(forTimeInterval: 0.01)
    var external = base; external.name = "external MCP change"; try external.save(to: shared,expecting: ProjectVersion.current(shared))
    base.style.padding = 0.1
    var conflict = false
    do { try base.save(to: shared,expecting: seen) } catch ProjectError.conflict { conflict = true }
    precondition(conflict,"Stale save must report a conflict")
    let (merged,_) = try Project.update(in: shared) { $0.style.padding = 0.1 }
    let disk = try Project.load(from: shared)
    precondition(merged.name == "external MCP change" && disk.name == "external MCP change" && abs(disk.style.padding-0.1) < 1e-9,"Both changes must survive")
    print("PASS: review regressions – export targets (14 aliases refused), command parsing (13 malformed), project opening, conflicting edits")
}

/// With real media: exporting onto an original fails and leaves its bytes unchanged (F1); an interrupted take with
/// a journal becomes an openable project, dropping a broken extra track (F4).
func testHardeningWithMedia(in root: URL) async throws {
    let dir = root.appendingPathComponent("hardening.rekord")
    try? FileManager.default.removeItem(at: dir)
    var project = try await makeFixture(at: dir)
    let screen = dir.appendingPathComponent("screen.mov")
    let digest = { (url: URL) throws -> String in SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x",$0) }.joined() }
    let before = try digest(screen)
    var refused = false
    do { try await MovieExporter.export(project: project,directory: dir,to: screen,height: 720,fps: 30) } catch { refused = true }
    let after = try digest(screen)
    precondition(refused && after == before,"Export onto screen.mov must fail and keep the original")

    // Interrupted take: project.json missing, journal present, microphone file unreadable.
    let journal = RecoveryJournal(directory: dir,template: { var t = project; t.name = "Abgebrochen"; t.hasMicrophone = true; return t }())
    journal.checkpoint(width: project.width,height: project.height,fps: project.fps,duration: 1,samples: project.pointer[...],cuts: nil,
                       hasCamera: project.hasCamera,hasMicrophone: true,cameraOffset: nil,microphoneOffset: 0)
    try Data("not audio".utf8).write(to: dir.appendingPathComponent("microphone.m4a"))
    try FileManager.default.removeItem(at: dir.appendingPathComponent("project.json"))
    let rescued = await RecoveryJournal.repairIncomplete(in: root,minimumAge: 0)
    precondition(rescued.map(\.lastPathComponent).contains("hardening.rekord"),"Interrupted take must be repaired")
    project = try Project.loadForEditing(from: dir)
    precondition(project.duration > 2.5 && project.hasMicrophone == false && project.name.hasSuffix("(gerettet)"),"Repaired take: full screen duration, broken microphone dropped")
    precondition(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(RecoveryJournal.journalName).path))
    print("PASS: review regressions with media – original survives export onto itself; interrupted take repaired (\(String(format: "%.1f",project.duration)) s)")
}

/// Cancelling an export at any moment (also exactly when the audio phase starts) ends with a clean
/// cancellation or a finished file – never a crash – and leaves an existing destination untouched.
func testExportCancellationStress(in root: URL) async throws {
    let dir = root.appendingPathComponent("cancel-stress.rekord")
    try? FileManager.default.removeItem(at: dir)
    let project = try await makeFixture(at: dir)
    let destination = root.appendingPathComponent("cancel-stress.mp4")
    try Data("keep".utf8).write(to: destination)
    var cancelled = 0, finished = 0, other: [String] = []
    for delay in [0.0,0.0005,0.002,0.01,0.03,0.06,0.1,0.15,0.2,0.3,0.45,0.6] {
        let job = Task { try await MovieExporter.export(project: project,directory: dir,to: destination,height: 720,fps: 30) }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay*1_000_000_000)) }
        job.cancel()
        do { try await job.value; finished += 1; try Data("keep".utf8).write(to: destination) }
        catch is CancellationError { cancelled += 1 }
        catch let error as NSError where error.domain == AVFoundationErrorDomain && error.code == AVError.Code.operationCancelled.rawValue { cancelled += 1 }
        catch { other.append(error.localizedDescription) }
        let kept = try String(contentsOf: destination,encoding: .utf8)
        precondition(kept == "keep","A cancelled export must leave the destination untouched")
    }
    // Exactly the crashing moment from the design review: cancelled right before the audio session starts.
    final class Box: @unchecked Sendable { var job: Task<Void,Error>? }
    let box = Box()
    MovieExporter.testHookBeforeAudioExport = { box.job?.cancel() }
    defer { MovieExporter.testHookBeforeAudioExport = nil }
    box.job = Task { try await MovieExporter.export(project: project,directory: dir,to: destination,height: 720,fps: 30) }
    do { try await box.job!.value; preconditionFailure("Export cancelled before the audio phase must not finish") } catch is CancellationError {}
    let keptAfterAudioCancel = try String(contentsOf: destination,encoding: .utf8)
    precondition(keptAfterAudioCancel == "keep")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".focus-export-") }
    precondition(leftovers.isEmpty,"Cancelled exports must remove their temporary folders: \(leftovers)")
    precondition(other.isEmpty,"Cancelling must end as a cancellation, not as a failure: \(other)")
    print("PASS: export cancelled at 12 moments plus exactly before the audio phase (\(cancelled) cancelled, \(finished) finished) – no crash, destination kept, no temp files")
}

/// Storage cleanup: only shared, idle Loom takes go to the Trash; only idle Studio takes move to a reachable
/// archive; open, interrupted, recent, unshared takes, meetings and guides stay.
func testStorageCleanup() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rekord-storage-\(UUID().uuidString)")
    let archive = root.appendingPathComponent("Archiv")
    defer { try? files.removeItem(at: root) }
    try files.createDirectory(at: archive,withIntermediateDirectories: true)
    let old = Date().addingTimeInterval(-40*86400)
    func take(_ name: String,mode: RecordingMode,shared: Bool = false,lastUsed: Date = old,journal: Bool = false) throws -> URL {
        let dir = root.appendingPathComponent("\(name).rekord")
        try files.createDirectory(at: dir,withIntermediateDirectories: true)
        var project = Project(name: name,duration: 2,width: 100,height: 100); project.mode = mode
        try project.save(to: dir); try Data(count: 2_000_000).write(to: dir.appendingPathComponent("screen.mov"))
        if shared { try Data("{}".utf8).write(to: dir.appendingPathComponent("share.json")) }
        if journal { try Data("{}".utf8).write(to: dir.appendingPathComponent(RecoveryJournal.journalName)) }
        try files.setAttributes([.modificationDate: lastUsed],ofItemAtPath: dir.appendingPathComponent("project.json").path)
        return dir
    }
    let loomOld = try take("loom-alt-geteilt",mode: .loom,shared: true)
    _ = try take("loom-alt-ohne-link",mode: .loom)
    _ = try take("loom-neu-geteilt",mode: .loom,shared: true,lastUsed: Date())
    let studioOld = try take("studio-alt",mode: .studio)
    let studioOpen = try take("studio-offen",mode: .studio)
    _ = try take("studio-abgebrochen",mode: .studio,journal: true)
    try files.createDirectory(at: root.appendingPathComponent("Meetings/m1"),withIntermediateDirectories: true)
    try Data(count: 500_000).write(to: root.appendingPathComponent("Meetings/m1/microphone.m4a"))

    let items = Storage.scan(root)
    precondition(items.count == 6,"Six recordings expected, got \(items.count)")
    let usage = Storage.usage(root)
    precondition(usage.loom >= 6_000_000 && usage.studio >= 6_000_000 && usage.meetings >= 500_000 && usage.freeOnDisk > 0)
    // Without an archive folder only Loom is cleaned.
    let loomOnly = Storage.plan(items,policy: Storage.Policy(loomTrashDays: 30),protected: [])
    precondition(loomOnly.map(\.item.url.lastPathComponent) == ["loom-alt-geteilt.rekord"],"Only the idle shared Loom take: \(loomOnly)")
    let policy = Storage.Policy(loomTrashDays: 30,studioArchiveDays: 30,archiveFolder: archive.path)
    let actions = Storage.plan(items,policy: policy,protected: [studioOpen.standardizedFileURL.path])
    precondition(Set(actions.map(\.item.url.lastPathComponent)) == ["loom-alt-geteilt.rekord","studio-alt.rekord"],"Plan: \(actions.map(\.item.url.lastPathComponent))")
    precondition(Storage.plan(items,policy: Storage.Policy(loomTrashDays: nil,studioArchiveDays: 30,archiveFolder: "/does/not/exist")).isEmpty,"Unreachable archive: nothing moves")
    let result = Storage.apply(actions)
    precondition(result.failed.isEmpty,"\(result.failed)")
    precondition(!files.fileExists(atPath: loomOld.path) && !files.fileExists(atPath: studioOld.path))
    let archived = archive.appendingPathComponent("studio-alt.rekord")
    let moves = result.moved.map { "\($0.from.path) -> \($0.to?.path ?? "Papierkorb")" }
    precondition(result.moved.contains { $0.from.lastPathComponent == "studio-alt.rekord" && $0.to?.standardizedFileURL.path == archived.standardizedFileURL.path },"Moves: \(moves)")
    do { _ = try Project.loadForEditing(from: archived) } catch { preconditionFailure("Archived take must stay openable: \(error)") }
    precondition(files.fileExists(atPath: root.appendingPathComponent("Meetings/m1/microphone.m4a").path))
    // Clean up the Trash copy of the test take.
    if let trash = try? files.url(for: .trashDirectory,in: .userDomainMask,appropriateFor: nil,create: false),
       let copy = try? files.contentsOfDirectory(at: trash,includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix("loom-alt-geteilt") }) { try? files.removeItem(at: copy) }
    print("PASS: storage – usage by area, only idle shared Loom to Trash, idle Studio to reachable archive (openable), open/interrupted/recent/unshared/meetings untouched")
}

/// Loom links are encoded with a bit-rate ceiling; ordinary exports keep their quality budget.
func testLoomBitRateCap(in root: URL) async throws {
    let dir = root.appendingPathComponent("bitrate.rekord")
    try? FileManager.default.removeItem(at: dir)
    let project = try await makeFixture(at: dir)
    let capped = root.appendingPathComponent("bitrate-capped.mp4"), normal = root.appendingPathComponent("bitrate-normal.mp4")
    try await MovieExporter.export(project: project,directory: dir,to: normal,height: 1080,fps: 30)
    try await MovieExporter.export(project: project,directory: dir,to: capped,height: 1080,fps: 30,maxBitRate: 1_000_000)
    func rate(_ url: URL) async throws -> Float { try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first!.load(.estimatedDataRate) }
    let cappedRate = try await rate(capped), normalRate = try await rate(normal)
    precondition(cappedRate < normalRate && cappedRate < 1_600_000,"Cap must lower the video data rate: \(cappedRate) vs \(normalRate)")
    precondition(MovieExporter.loomBitRate == 6_000_000)
    print(String(format: "PASS: bit-rate cap honoured (%.1f vs %.1f Mbit/s), Loom ceiling 6 Mbit/s",cappedRate/1e6,normalRate/1e6))
}

/// Library: user folders next to the takes, moves keep projects openable, reserved and hidden folders stay out,
/// dissolving a folder brings its takes back, temporary paths are recognised.
func testLibrary() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rekord-library-\(UUID().uuidString)")
    defer { try? files.removeItem(at: root) }
    try files.createDirectory(at: root,withIntermediateDirectories: true)
    func take(_ name: String,in folder: URL) throws -> URL {
        let dir = folder.appendingPathComponent("\(name).rekord")
        try files.createDirectory(at: dir,withIntermediateDirectories: true)
        try Project(name: name,duration: 2,width: 100,height: 100).save(to: dir)
        try Data(count: 16).write(to: dir.appendingPathComponent("screen.mov"))
        return dir
    }
    let a = try take("a",in: root), b = try take("b",in: root)
    for reserved in ["Meetings","Anleitungen","Inventur",".focus-export"] { try files.createDirectory(at: root.appendingPathComponent(reserved),withIntermediateDirectories: true) }
    _ = try take("meeting-artig",in: root.appendingPathComponent("Meetings"))
    let kunden = try Library.createFolder("  Kunden ",in: root)
    precondition(kunden.lastPathComponent == "Kunden","Name is trimmed")
    for bad in ["","Kunden","kunden","meetings","a/b",".x","x.rekord"] {
        precondition((try? Library.createFolder(bad,in: root)) == nil,"Folder name must be refused: '\(bad)'")
    }
    precondition(Library.folders(in: root).map(\.lastPathComponent) == ["Kunden"],"Only user folders: \(Library.folders(in: root).map(\.lastPathComponent))")
    let moved = try Library.move(a,to: kunden)
    precondition(!files.fileExists(atPath: a.path) && Library.folder(of: moved,root: root) == "Kunden")
    _ = try Project.load(from: moved)
    precondition(Set(Library.projects(in: root).map(\.lastPathComponent)) == ["a.rekord","b.rekord"],"Projects in root and folders, none from Meetings")
    precondition(Set(Storage.scan(root).map(\.url.lastPathComponent)) == ["a.rekord","b.rekord"],"Storage sees folders too")
    // Same name in the target folder gets a number instead of overwriting.
    let clash = try take("a",in: root)
    let numbered = try Library.move(clash,to: kunden)
    precondition(numbered.lastPathComponent == "a 2.rekord","Clash: \(numbered.lastPathComponent)")
    // A take that is still being recorded stays put.
    try Data("{}".utf8).write(to: b.appendingPathComponent(RecoveryJournal.journalName))
    precondition((try? Library.move(b,to: kunden)) == nil && (try? Library.trash(b)) == nil,"Recording take must not move")
    try files.removeItem(at: b.appendingPathComponent(RecoveryJournal.journalName))
    let renamed = try Library.renameFolder(kunden,to: "Kunden 2026")
    precondition(Library.projects(directlyIn: renamed).count == 2)
    let cased = try Library.renameFolder(renamed,to: "KUNDEN 2026")
    precondition(cased.lastPathComponent == "KUNDEN 2026")
    let back = try Library.dissolveFolder(cased,into: root)
    precondition(back.count == 2 && Library.folders(in: root).isEmpty && Library.projects(directlyIn: root).count == 3,"Dissolve brings takes back: \(back.map(\.to.lastPathComponent))")
    precondition(Library.isTemporary(URL(fileURLWithPath: "/tmp/rd-before/x.rekord")) && Library.isTemporary(root)
                 && !Library.isTemporary(URL(fileURLWithPath: NSHomeDirectory()+"/Movies/Rekord/x.rekord")),"Temporary paths")
    // Clean up the Trash copy of the dissolved folder.
    if let trash = try? files.url(for: .trashDirectory,in: .userDomainMask,appropriateFor: nil,create: false),
       let copy = try? files.contentsOfDirectory(at: trash,includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix("KUNDEN 2026") }) { try? files.removeItem(at: copy) }
    print("PASS: library – user folders (reserved/hidden skipped), move with numbered clash, recording takes stay, rename incl. case, dissolve, temp paths")
}

/// App calls: only a request file with the local key, the matching operation and a fresh timestamp is accepted;
/// a rekord://call URL alone (e.g. from a web page) never runs anything.
func testAppCalls() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rekord-calls-\(UUID().uuidString)")
    defer { try? files.removeItem(at: root); unsetenv("REKORD_SUPPORT_ROOT") }
    setenv("REKORD_SUPPORT_ROOT",root.path,1)
    let key = try AppCall.key()
    let again = try AppCall.key()
    precondition(key.count == 64 && again == key,"Key is created once and reused")
    let mode = (try files.attributesOfItem(atPath: root.appendingPathComponent("call-key").path)[.posixPermissions] as? NSNumber)?.intValue
    precondition(mode == 0o600,"Key file must be private, got \(String(mode ?? 0,radix: 8))")
    try Data("kaputt".utf8).write(to: root.appendingPathComponent("call-key"))
    let replaced = try AppCall.key()
    precondition(replaced.count == 64 && replaced != key,"A damaged key file is replaced instead of looping")
    let current = replaced
    // Round trip.
    try AppCall.writeRequest(id: "job-1",op: "library.move",arguments: ["recording": "/x.rekord","folder": "Kunden"])
    let args = try AppCall.readRequest(id: "job-1",op: "library.move")
    _ = current
    precondition(args["folder"] as? String == "Kunden","Arguments survive")
    precondition((try? AppCall.readRequest(id: "job-1",op: "library.move")) == nil,"A request is consumed once")
    // URL without request file, wrong op, wrong key, stale request.
    precondition((try? AppCall.readRequest(id: "job-2",op: "library.trash")) == nil,"No file, no call")
    try AppCall.writeRequest(id: "job-3",op: "library.move",arguments: [:])
    precondition((try? AppCall.readRequest(id: "job-3",op: "library.trash")) == nil,"Operation must match the file")
    for (id,body) in [("job-4",["key": String(repeating: "0",count: 64),"op": "library.trash","arguments": [:],"created": Date().timeIntervalSince1970] as [String: Any]),
                      ("job-5",["key": current,"op": "library.trash","arguments": [:],"created": Date().timeIntervalSince1970-600] as [String: Any])] {
        try JSONSerialization.data(withJSONObject: body).write(to: AppCall.folder.appendingPathComponent("\(id).request.json"))
        precondition((try? AppCall.readRequest(id: id,op: "library.trash")) == nil,"\(id) must be refused")
    }
    for bad in ["../x","a/b","",String(repeating: "a",count: 200)] { precondition(!AppCall.validID(bad),"id \(bad)") }
    for bad in ["library","Library.move","library.move;rm","library..x","x.y.z"] { precondition(!AppCall.validOperation(bad),"op \(bad)") }
    AppCall.writeResult(id: "job-1",result: ["path": "/y"],error: nil)
    precondition(AppCall.takeResult(id: "job-1")?.result["path"] as? String == "/y" && AppCall.takeResult(id: "job-1") == nil,"Result is read once")
    // Parser: call needs op and id, nothing else.
    precondition((try? AppCommand.parse(URL(string: "rekord://call?op=library.move&id=j1")!))?.op == "library.move")
    for bad in ["rekord://call?op=library.move","rekord://call?id=j1","rekord://call?op=library.move&id=j1&path=/x","rekord://call?op=../x&id=j1"] {
        precondition((try? AppCommand.parse(URL(string: bad)!)) == nil,"Must refuse \(bad)")
    }
    print("PASS: app calls – private key file, consumed once, op must match, wrong key/stale/missing file refused, strict ids and parser")
}
