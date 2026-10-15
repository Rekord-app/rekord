import AppKit
import AVFoundation
import RecorderCore

/// `--command-check <dir> --project <x.rekord>`: the real rekord:// handler against the review's reproductions
/// (F2 share of a missing/broken project must not touch the open one, F3 duplicate parameters must not crash,
/// F5 an edit right after an external change keeps both). Works on a copy; nothing is uploaded.
/// `--fault-check <dir>`: a real 3 s display take whose microphone encoder fails (F4) must still end as an
/// openable project without the microphone track. Needs screen and microphone access.
@MainActor enum HardeningDiagnostics {
    static func run(arguments: [String]) async {
        if let i = arguments.firstIndex(of: "--command-check"),arguments.count > i+1,
           let p = arguments.firstIndex(of: "--project"),arguments.count > p+1 {
            await commands(root: URL(fileURLWithPath: arguments[i+1]),fixture: URL(fileURLWithPath: arguments[p+1]))
        }
        if let i = arguments.firstIndex(of: "--fault-check"),arguments.count > i+1 { await fault(root: URL(fileURLWithPath: arguments[i+1])) }
    }
    private static func reporter(_ file: URL) -> (String) -> Void {
        var lines: [String] = []
        return { line in lines.append(line); try? lines.joined(separator: "\n").write(to: file,atomically: true,encoding: .utf8) }
    }
    private static func wait(_ seconds: Double,until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if condition() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return condition()
    }
    static func commands(root: URL,fixture: URL) async {
        try? FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let log = reporter(root.appendingPathComponent("command-report.txt"))
        let recent = UserDefaults.standard.object(forKey: "recentProjects")
        defer { UserDefaults.standard.set(recent,forKey: "recentProjects") }
        do {
            let files = FileManager.default
            let open = root.appendingPathComponent("open.rekord"), broken = root.appendingPathComponent("broken.rekord"), noScreen = root.appendingPathComponent("no-screen.rekord")
            for dir in [open,broken,noScreen] { try? files.removeItem(at: dir) }
            try files.copyItem(at: fixture,to: open); try files.copyItem(at: fixture,to: broken); try files.copyItem(at: fixture,to: noScreen)
            try Data("{ broken".utf8).write(to: broken.appendingPathComponent("project.json"))
            try files.removeItem(at: noScreen.appendingPathComponent("screen.mov"))
            let store = EditorStore(captureRoot: root)
            store.open(open)
            guard store.directory?.path == open.path else { throw RecorderError.message("Fixture did not open") }
            store.shareConfigured = true   // in memory only: proves share() is never reached for the wrong project
            for (name,target) in [("missing",root.appendingPathComponent("does-not-exist.rekord")),("broken JSON",broken),("missing screen.mov",noScreen)] {
                store.error = nil
                var components = URLComponents(); components.scheme = "rekord"; components.host = "share"
                components.queryItems = [URLQueryItem(name: "path",value: target.path),URLQueryItem(name: "id",value: "probe")]
                store.handleCommand(components.url!)
                try? await Task.sleep(nanoseconds: 200_000_000)
                let result = store.lastCommand
                guard store.phase == .idle, store.directory?.path == open.path, result?["ok"] as? Bool == false, result?["id"] as? String == "probe" else {
                    throw RecorderError.message("share of \(name) project started or changed the open project (phase \(store.phase))")
                }
                log("PASS share of \(name) project: rejected (\(result?["error"] as? String ?? "")), open project untouched, no export")
            }
            for raw in ["rekord://stop?x=1&x=2","rekord://pause?id=a&id=b","rekord://launch","rekord://share","rekord://stop"] {
                store.handleCommand(URL(string: raw)!)
                guard store.lastCommand?["ok"] as? Bool == false else { throw RecorderError.message("\(raw) was not rejected") }
            }
            log("PASS duplicate/unknown/incomplete commands rejected without crashing (5 cases)")
            // F5: change on disk right before a UI edit, inside the 1 s polling window.
            var external = try Project.load(from: open); external.name = "external MCP change"
            try external.save(to: open)
            store.edit { $0.style.padding = 0.11 }
            let disk = try Project.load(from: open)
            guard disk.name == "external MCP change", abs(disk.style.padding-0.11) < 1e-9 else { throw RecorderError.message("Edit dropped the external change: \(disk.name)") }
            log("PASS UI edit within the polling window keeps the external change")
            log("DONE")
        } catch { log("FAIL \(error.localizedDescription)") }
    }
    static func fault(root: URL) async {
        try? FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let log = reporter(root.appendingPathComponent("fault-report.txt"))
        let recent = UserDefaults.standard.object(forKey: "recentProjects")
        defer { UserDefaults.standard.set(recent,forKey: "recentProjects"); ScreenRecorder.faultInjection = nil }
        do {
            guard CGPreflightScreenCaptureAccess() else { log("BLOCKED screen grant"); return }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { log("BLOCKED microphone grant"); return }
            let store = EditorStore(captureRoot: root)
            store.withCamera = false; store.withMicrophone = true
            store.openRecorder()
            guard await wait(10,until: { !store.sources.isEmpty && !store.sourcesLoading }) else { throw RecorderError.message("Recorder did not open") }
            store.recorderHUD.overlays.select(.display,store: store)
            store.prepareActiveSourceForStart()
            ScreenRecorder.faultInjection = "microphone"
            store.startRecording()
            guard await wait(20,until: { store.phase == .recording }) else { throw RecorderError.message(store.error ?? "Take did not start") }
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let warned = store.trackProblem != nil
            store.stopRecording()
            guard await wait(20,until: { store.phase == .idle }), let project = store.project, let dir = store.directory else { throw RecorderError.message(store.error ?? "Take was lost") }
            let reopened = try Project.loadForEditing(from: dir)
            guard warned, reopened.hasMicrophone == false, reopened.duration > 2, store.error?.contains("nicht vollständig") == true else {
                throw RecorderError.message("Partial take not saved correctly (microphone \(String(describing: reopened.hasMicrophone)), \(reopened.duration) s)")
            }
            guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent(RecoveryJournal.journalName).path) else { throw RecorderError.message("Journal left behind") }
            log("PASS failing microphone: take saved and reopened (\(String(format: "%.1f",project.duration)) s, no microphone track), warning during take \(warned), user told it is incomplete")
            log("DONE")
        } catch { log("FAIL \(error.localizedDescription)") }
    }
}
