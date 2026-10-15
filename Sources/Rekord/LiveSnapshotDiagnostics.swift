import AppKit
import SwiftUI
import ScreenCaptureKit
import AVFoundation
import ImageIO
import RecorderCore

/// `--ui-live-snapshot <dir>`: runs the real recorder UI on screen for a moment and captures only this app's own
/// windows with ScreenCaptureKit, so Liquid Glass and live camera render exactly as the user sees them.
@MainActor enum LiveSnapshotDiagnostics {
    static func run(arguments: [String]) async {
        guard let i = arguments.firstIndex(of: "--ui-live-snapshot"),arguments.count > i+1 else { return }
        let root = URL(fileURLWithPath: arguments[i+1])
        try? FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        var log: [String] = []
        defer { try? log.joined(separator: "\n").write(to: root.appendingPathComponent("live-snapshot.txt"),atomically: true,encoding: .utf8) }
        guard CGPreflightScreenCaptureAccess() else { log.append("BLOCKED screen grant"); return }
        let recent = UserDefaults.standard.object(forKey: "recentProjects")
        defer { UserDefaults.standard.set(recent,forKey: "recentProjects") }
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds*1_000_000_000)) }
        let store = EditorStore()
        store.withCamera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        store.withMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        // Home in the main window.
        let window = NSWindow(contentRect: CGRect(x: 0,y: 0,width: 1320,height: 860),styleMask: [.titled,.closable,.fullSizeContentView],backing: .buffered,defer: false)
        window.title = "Rekord"; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: EditorView().environmentObject(store).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        await pause(1.5)
        await capture([window],to: root.appendingPathComponent("1-home.png"),log: &log)
        if let p = arguments.firstIndex(of: "--project"),arguments.count > p+1 {
            let copy = root.appendingPathComponent("project.rekord")
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[p+1]),to: copy)
            store.open(copy)
            for _ in 0..<100 where !store.playerReady { await pause(0.1) }
            store.seekEdited(min(3.6,store.project?.editedDuration ?? 0)); await pause(4)
            await capture([window],to: root.appendingPathComponent("7-editor.png"),log: &log)
            store.inspectorTab = .zoom; await pause(0.5)
            await capture([window],to: root.appendingPathComponent("8-editor-zoom.png"),log: &log)
            if let split = store.project?.cameraLayouts?.first(where: { $0.layout == .split }) {
                store.seekSource((split.start+split.end)/2); store.selectedLayout = split.id
            }
            store.inspectorTab = .camera; await pause(1.5)
            await capture([window],to: root.appendingPathComponent("9-editor-camera.png"),log: &log)
            store.inspectorTab = .appearance
            if arguments.contains("--editor-only") { window.orderOut(nil); return }
            store.showRecordingSetup(); await pause(0.4)
        }
        // Floating recorder.
        store.mainWindow = window
        store.openRecorder()
        for _ in 0..<100 where store.sources.isEmpty || store.sourcesLoading { await pause(0.1) }
        await pause(1.5)
        let hud = store.recorderHUD
        hud.makeCapturable(); hud.overlays.makeCapturable(); await pause(0.3)
        await capture(hud.windows+hud.overlays.overlayWindows,to: root.appendingPathComponent("2-recorder-display.png"),log: &log)
        hud.overlays.select(.window,store: store); for _ in 0..<40 where store.sourcesLoading { await pause(0.05) }
        hud.overlays.model.refreshWindowList()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if let screen = NSScreen.screens.first {
            let centre = CGPoint(x: screen.frame.midX,y: primaryHeight-screen.frame.midY)
            hud.overlays.model.hoveredWindow = hud.overlays.model.window(atGlobal: centre)
        }
        hud.makeCapturable(); hud.overlays.makeCapturable(); await pause(0.6)
        await capture(hud.windows+hud.overlays.overlayWindows,to: root.appendingPathComponent("3-recorder-window.png"),log: &log)
        hud.overlays.select(.area,store: store); for _ in 0..<40 where store.sourcesLoading { await pause(0.05) }
        if let display = store.sources.first(where: { $0.display != nil })?.display {
            let w = Double(display.width)*0.62
            store.areaSource = CaptureSource.area(CGRect(x: Double(display.width)*0.19,y: 120,width: w,height: w*9/16),on: display)
        }
        hud.overlays.update(store: store)
        hud.makeCapturable(); hud.overlays.makeCapturable(); await pause(0.6)
        await capture(hud.windows+hud.overlays.overlayWindows,to: root.appendingPathComponent("4-recorder-area.png"),log: &log)
        // Recording pill (UI state only; nothing is recorded).
        store.phase = .recording; store.elapsed = 83; hud.overlays.update(store: store)
        hud.makeCapturable(); hud.overlays.makeCapturable(); await pause(0.6)
        await capture(hud.windows+hud.overlays.overlayWindows,to: root.appendingPathComponent("5-recording-pill.png"),log: &log)
        store.paused = true; await pause(0.4)
        await capture(hud.windows,to: root.appendingPathComponent("6-recording-paused.png"),log: &log)
        store.paused = false; store.phase = .idle
        store.closeRecorder(); await store.monitor.stop(); window.orderOut(nil)
    }
    /// Captures the given windows of this app composited together (display region covering them).
    private static func capture(_ windows: [NSWindow],to url: URL,log: inout [String]) async {
        do {
            // The shareable window list can lag behind; retry briefly before giving up.
            let ids = Set(windows.map { CGWindowID($0.windowNumber) })
            var content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly: true)
            var included = content.windows.filter { ids.contains($0.windowID) }
            for _ in 0..<8 where included.count < ids.count {
                try await Task.sleep(nanoseconds: 400_000_000)
                content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly: true)
                included = content.windows.filter { ids.contains($0.windowID) }
            }
            guard let display = content.displays.first, !included.isEmpty else {
                let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                log.append("FAIL nothing to capture for \(url.lastPathComponent): wanted \(ids.sorted()), visible \(windows.map(\.isVisible)), own SC windows \(own.map { "\($0.windowID) \($0.isOnScreen) \($0.frame.size)" })")
                return
            }
            let filter = SCContentFilter(display: display,including: included)
            let config = SCStreamConfiguration()
            config.width = display.width*2; config.height = display.height*2; config.showsCursor = false
            // The configuration does not retain its background colour; keep it alive for the capture.
            let background = CGColor(red: 0.16,green: 0.17,blue: 0.2,alpha: 1)
            config.backgroundColor = background
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,configuration: config)
            withExtendedLifetime(background) {}
            let destination = CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
            CGImageDestinationAddImage(destination,image,nil); _ = CGImageDestinationFinalize(destination)
            log.append("PASS \(url.lastPathComponent) \(image.width)×\(image.height) (\(included.count) windows)")
        } catch { log.append("FAIL \(url.lastPathComponent): \(error.localizedDescription)") }
    }
}
