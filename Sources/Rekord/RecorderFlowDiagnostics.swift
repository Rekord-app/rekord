import AppKit
import AVFoundation
import RecorderCore

/// `--recorder-flow-check <dir>`: the floating recorder end to end with real capture — area take to the editor,
/// window take discarded, display take restarted then stopped. Recordings stay in the diagnostic directory.
@MainActor enum RecorderFlowDiagnostics {
    static func run(arguments: [String]) async {
        guard let i = arguments.firstIndex(of: "--recorder-flow-check"),arguments.count > i+1 else { return }
        let root = URL(fileURLWithPath: arguments[i+1])
        var lines: [String] = []
        func log(_ value: String) { lines.append(value); try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("recorder-flow-report.txt"),atomically: true,encoding: .utf8) }
        func wait(_ seconds: Double,until condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if condition() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
            return condition()
        }
        let recent = UserDefaults.standard.object(forKey: "recentProjects")
        defer { UserDefaults.standard.set(recent,forKey: "recentProjects") }
        do {
            try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            guard CGPreflightScreenCaptureAccess() else { log("BLOCKED screen grant"); return }
            let store = EditorStore(captureRoot: root)
            store.withCamera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            store.withMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            store.openRecorder()
            guard await wait(10,until: { !store.sources.isEmpty && !store.sourcesLoading }), store.hudActive else { throw RecorderError.message("Recorder did not open") }
            log("PASS recorder opened: toolbar + camera bubble, \(store.sources.count) sources, camera \(store.withCamera), microphone \(store.withMicrophone)")
            let hud = store.recorderHUD

            // 1. Area (16:9 below the menu bar) → Stop → editor.
            hud.overlays.select(.area,store: store)
            guard await wait(5,until: { !store.sourcesLoading }), let display = store.sources.first(where: { $0.display != nil })?.display else { throw RecorderError.message("No display") }
            let height = min(Double(display.height)-37,Double(display.width)*9/16)
            store.areaSource = CaptureSource.area(CGRect(x: 0,y: 37,width: height*16/9,height: height),on: display)
            store.startRecording()
            guard await wait(20,until: { store.phase == .recording }) else { throw RecorderError.message(store.error ?? "Area take did not start") }
            try await Task.sleep(nanoseconds: 3_000_000_000)
            store.stopRecording()
            guard await wait(20,until: { store.phase == .idle && store.project != nil }), let project = store.project else { throw RecorderError.message(store.error ?? "Area take did not finish") }
            guard !store.hudActive, store.workspace == .edit, hud.windows.isEmpty, hud.overlays.overlayWindows.isEmpty else { throw RecorderError.message("Recorder UI did not close after Stop") }
            guard abs(Double(project.width)/Double(project.height)-16.0/9.0) < 0.01 else { throw RecorderError.message("Area take is not 16:9: \(project.width)×\(project.height)") }
            log("PASS area take \(project.width)×\(project.height), \(String(format: "%.2f",project.duration)) s → editor opened, recorder windows closed")

            // 2. Window → discard.
            store.openRecorder()
            hud.overlays.select(.window,store: store)
            guard await wait(5,until: { !store.sourcesLoading }), let window = store.sources.first(where: { $0.window != nil }) else { throw RecorderError.message("No window source") }
            store.selectedSource = window.id
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            store.startRecording()
            guard await wait(20,until: { store.phase == .recording }) else { throw RecorderError.message(store.error ?? "Window take did not start") }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            store.discardRecording()
            guard await wait(20,until: { store.phase == .idle }), store.hudActive else { throw RecorderError.message("Discard did not return to the recorder") }
            let after = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            guard after.subtracting(before).isEmpty else { throw RecorderError.message("Discarded take left files: \(after.subtracting(before))") }
            log("PASS window take “\(window.title)” discarded: back in the recorder, no files left")

            // 3. Display → restart → stop.
            hud.overlays.select(.display,store: store)
            store.prepareActiveSourceForStart()
            store.startRecording()
            guard await wait(20,until: { store.phase == .recording }) else { throw RecorderError.message(store.error ?? "Display take did not start") }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            store.restartRecording()
            guard await wait(25,until: { store.phase == .recording && store.elapsed < 1.5 }) else { throw RecorderError.message("Restart did not start a fresh take") }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            store.stopRecording()
            guard await wait(20,until: { store.phase == .idle && !store.hudActive }), let restarted = store.project else { throw RecorderError.message(store.error ?? "Restarted take did not finish") }
            let takes = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { ProjectFolder.isProject(URL(fileURLWithPath: $0)) }
            guard takes.count == 2, (1.5...3.5).contains(restarted.duration) else { throw RecorderError.message("Restart kept the first take or wrong length: \(takes), \(restarted.duration) s") }
            log("PASS display take restarted (first take deleted), new take \(String(format: "%.2f",restarted.duration)) s → editor")
            if CropRect.automaticWidescreen(sourceWidth: restarted.width,sourceHeight: restarted.height) != nil {
                guard store.autoWidescreen, let crop = restarted.style.crop else { throw RecorderError.message("MacBook display take was not cropped to 16:9") }
                let view = restarted.applyingCrop()
                guard abs(Double(view.width)/Double(view.height)-16.0/9.0) < 0.01, crop.y > 0.02, crop.y < 0.06 else { throw RecorderError.message("Auto crop is not 16:9 without menu bar: \(crop)") }
                log("PASS display \(restarted.width)×\(restarted.height) auto-cropped to 16:9 \(view.width)×\(view.height) (menu bar \(String(format: "%.1f",crop.y*100)) %, rest from the Dock)")
            }

            // 4. Commands as sent by the MCP server (rekord://start?source=area-16:9, stop) and the status file.
            store.handleCommand(URL(string: "rekord://start?source=area-16:9")!)
            guard await wait(25,until: { store.phase == .recording }) else { throw RecorderError.message(store.error ?? "start command did not record") }
            let statusFile = SupportFolder.url.appendingPathComponent("status.json")
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let status = (try? JSONSerialization.jsonObject(with: Data(contentsOf: statusFile)) as? [String: Any]) ?? [:]
            guard status["phase"] as? String == "recording" else { throw RecorderError.message("status.json does not report recording: \(status)") }
            store.handleCommand(URL(string: "rekord://stop")!)
            guard await wait(20,until: { store.phase == .idle && store.project != nil && !store.hudActive }), let commanded = store.project else { throw RecorderError.message(store.error ?? "stop command did not finish") }
            guard abs(Double(commanded.width)/Double(commanded.height)-16.0/9.0) < 0.01 else { throw RecorderError.message("Commanded area is not 16:9") }
            guard commanded.style.crop == nil else { throw RecorderError.message("Area take must not be auto-cropped") }
            log("PASS rekord:// start (16:9 area) and stop: \(commanded.width)×\(commanded.height), status.json reported recording, editor opened")
            log("DONE")
        } catch { log("FAIL \(error.localizedDescription)") }
    }
}
