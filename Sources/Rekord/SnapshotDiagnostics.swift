import AppKit
import SwiftUI
import RecorderCore

/// `--ui-snapshot <dir> [--project <recording.rekord>]`: renders the app's own views in an offscreen window
/// to PNG for layout review. Draws only this app's content, so no screen-recording permission is involved and
/// no camera/microphone session is opened. Live layers (player, camera preview) appear empty in snapshots.
@MainActor enum SnapshotDiagnostics {
    /// True while snapshots render: views then show the finished state instead of permission hints.
    static var active = false
    static func run(arguments: [String]) async {
        guard let i = arguments.firstIndex(of: "--ui-snapshot"),arguments.count > i+1 else { return }
        let root = URL(fileURLWithPath: arguments[i+1])
        try? FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let recent = UserDefaults.standard.object(forKey: "recentProjects")
        defer { UserDefaults.standard.set(recent,forKey: "recentProjects") }
        // Meetings and guides come from synthetic fixtures in the snapshot folder, never from the user's own data.
        let meetingsRoot = root.appendingPathComponent("Meetings"), guidesRoot = root.appendingPathComponent("Anleitungen")
        _ = try? SnapshotFixtures.makeMeetings(in: meetingsRoot)
        _ = try? SnapshotFixtures.makeGuides(in: guidesRoot)
        active = true; defer { active = false }
        // The library reads only the snapshot folder, never the user's recordings.
        let library = root.appendingPathComponent("Bibliothek")
        try? FileManager.default.removeItem(at: library)
        try? FileManager.default.createDirectory(at: library,withIntermediateDirectories: true)
        let store = EditorStore(captureRoot: library,meetingsRoot: meetingsRoot,guidesRoot: guidesRoot)
        store.recent = []; store.refreshLibrary()
        store.withCamera = true; store.withMicrophone = true
        // The library shows copies of the fixture under dated names (today, yesterday, earlier) instead of the user's recordings.
        if let p = arguments.firstIndex(of: "--project"),arguments.count > p+1 {
            let source = URL(fileURLWithPath: arguments[p+1])
            for folder in ["Kunden","YouTube"] { try? FileManager.default.createDirectory(at: library.appendingPathComponent(folder),withIntermediateDirectories: true) }
            let stamp = DateFormatter(); stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
            var copies: [URL] = []
            for (offset,title,folder) in [(0.0,"",""),(0.25,"Kundendemo Scale OS","Kunden"),(1.1,"",""),(1.4,"Onboarding Lead-Magnet","Kunden"),(3.2,"","YouTube"),(9.0,"",""),(20.0,"Pitch Rekord Meetings","")] {
                let date = Date().addingTimeInterval(-offset*86400)
                let copy = (folder.isEmpty ? library : library.appendingPathComponent(folder)).appendingPathComponent("Aufnahme \(stamp.string(from: date)).rekord")
                try? FileManager.default.removeItem(at: copy)
                guard (try? FileManager.default.copyItem(at: source,to: copy)) != nil, var project = try? Project.load(from: copy) else { continue }
                if !title.isEmpty { project.name = title; try? project.save(to: copy) }
                copies.append(copy)
            }
            store.recent = Array(copies.prefix(3)); store.refreshLibrary()
        }
        await snapshot(EditorView().environmentObject(store),size: CGSize(width: 1320,height: 860),to: root.appendingPathComponent("1-setup.png"))
        if !store.folders.isEmpty {
            store.folderFilter = "Kunden"
            await snapshot(EditorView().environmentObject(store),size: CGSize(width: 1320,height: 860),to: root.appendingPathComponent("1c-folder.png"))
            store.folderFilter = nil
        }
        if arguments.contains("--no-meetings") == false {
            store.showMeetings()
            await snapshot(EditorView().environmentObject(store),size: CGSize(width: 1320,height: 860),to: root.appendingPathComponent("5-meetings.png"))
            store.meetings.selected = store.meetings.meetings.first { (try? MeetingSummary.load(from: $0)) != nil }
            await snapshot(EditorView().environmentObject(store),size: CGSize(width: 1320,height: 860),to: root.appendingPathComponent("5b-meeting-detail.png"))
            await snapshot(SettingsSheet(meetings: store.meetings).environmentObject(store),size: CGSize(width: 580,height: 680),to: root.appendingPathComponent("5c-meeting-settings.png"))
            await snapshot(Form { StorageSettingsSection(); Section("Teilen") { ShareExpiryPicker() } }.formStyle(.grouped).scrollContentBackground(.hidden)
                        .frame(width: 580,height: 560).background(StudioTheme.background).environmentObject(store).preferredColorScheme(.dark),
                     size: CGSize(width: 580,height: 560),to: root.appendingPathComponent("5e-storage-settings.png"))
            store.meetings.elapsed = 754; store.meetings.microphoneLevel = 0.55; store.meetings.systemLevel = 0.3; store.meetings.callApp = "Google Meet"
            await snapshot(MeetingControllerView(meetings: store.meetings),size: CGSize(width: 250,height: 118),to: root.appendingPathComponent("5d-meeting-controller.png"))
            store.showGuides()
            await snapshot(EditorView().environmentObject(store),size: CGSize(width: 1320,height: 860),to: root.appendingPathComponent("6-guides.png"))
            store.guides.selected = store.guides.guides.first
            await snapshot(EditorView().environmentObject(store),size: CGSize(width: 1320,height: 860),to: root.appendingPathComponent("6b-guide-detail.png"))
            store.guides.elapsed = 96; store.guides.clicks = 7
            await snapshot(GuideControllerView(guides: store.guides),size: CGSize(width: 236,height: 92),to: root.appendingPathComponent("6c-guide-controller.png"))
            await snapshot(ShareSettingsView().environmentObject(store),size: CGSize(width: 540,height: 420),to: root.appendingPathComponent("6d-share-settings.png"))
            await snapshot(ShareLibraryView().environmentObject(store),size: CGSize(width: 720,height: 520),to: root.appendingPathComponent("6e-share-library.png"))
            await snapshot(InventoryView(inventory: store.inventory).environmentObject(store),size: CGSize(width: 1100,height: 740),to: root.appendingPathComponent("7-inventory.png"))
            store.showRecordingSetup()
        }
        // Setup preview with a synthetic screen, as the live monitor would show it.
        let screen = CGContext(data: nil,width: 1470,height: 956,bitsPerComponent: 8,bytesPerRow: 1470*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        screen.setFillColor(CGColor(red: 0.93,green: 0.94,blue: 0.96,alpha: 1)); screen.fill(CGRect(x: 0,y: 0,width: 1470,height: 956))
        screen.setFillColor(CGColor(red: 0.2,green: 0.35,blue: 0.85,alpha: 1)); screen.fill(CGRect(x: 0,y: 900,width: 1470,height: 56))
        screen.setFillColor(CGColor(red: 0.85,green: 0.86,blue: 0.9,alpha: 1)); screen.fill(CGRect(x: 0,y: 0,width: 300,height: 900))
        let receive = store.monitor.receiver(mode: .studio,style: store.recordingStyle)
        receive(CapturePreviewSample(image: screen.makeImage()))
        for _ in 0..<100 where store.monitor.frame == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        await snapshot(EditorView().environmentObject(store),size: CGSize(width: 1320,height: 860),to: root.appendingPathComponent("1b-setup-live.png"))
        await snapshot(RecordingControllerView(store: store,monitor: store.monitor),size: CGSize(width: 240,height: 282),to: root.appendingPathComponent("2-floating-controller.png"))
        store.paused = true
        await snapshot(RecordingControllerView(store: store,monitor: store.monitor),size: CGSize(width: 240,height: 282),to: root.appendingPathComponent("2b-floating-paused.png"))
        store.paused = false
        if let p = arguments.firstIndex(of: "--project"),arguments.count > p+1 {
            let copy = root.appendingPathComponent("project.rekord")
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[p+1]),to: copy)
            store.open(copy)
            for _ in 0..<300 where !store.playerReady { try? await Task.sleep(nanoseconds: 20_000_000) }
            await snapshot(EditorView().environmentObject(store),size: CGSize(width: 1320,height: 860),to: root.appendingPathComponent("3-editor.png"))
            store.inspectorTab = .zoom
            await snapshot(EditorView().environmentObject(store),size: CGSize(width: 1320,height: 860),to: root.appendingPathComponent("3b-zoom-tab.png"))
            store.inspectorTab = .export
            if let project = store.project, let directory = store.directory {
                store.exports.enqueue(project: project,directory: directory,destination: root.appendingPathComponent("snapshot-export.mp4"),height: 1080,fps: 30)
                store.exports.enqueue(project: project,directory: directory,destination: root.appendingPathComponent("snapshot-export-4k.mp4"),height: 2160,fps: 60)
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            await snapshot(EditorView().environmentObject(store),size: CGSize(width: 1320,height: 860),to: root.appendingPathComponent("3c-export-tab.png"))
            store.exports.cancelAll()
            store.inspectorTab = .appearance
            if let duration = store.project?.duration, duration > 2.5 {
                store.edit { $0.cuts = [Cut(start: 0,end: duration*0.4),Cut(start: duration*0.6,end: duration)] }
                for _ in 0..<300 where !store.playerReady { try? await Task.sleep(nanoseconds: 20_000_000) }
                store.seekSource(duration*0.5)
                for _ in 0..<300 where store.removedFrame == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
                store.inspectorTab = .cut
                await snapshot(EditorView().environmentObject(store),size: CGSize(width: 1320,height: 860),to: root.appendingPathComponent("4-editor-removed-range.png"))
            }
        }
    }
    static func snapshot<V: View>(_ view: V,size: CGSize,to url: URL) async {
        // Sheets and panels get the window background they would have in a real window.
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark).frame(width: size.width,height: size.height).background(StudioTheme.background))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000,y: -10000),size: size),styleMask: [.borderless],backing: .buffered,defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; window.orderBack(nil)
        host.layoutSubtreeIfNeeded(); host.display()
        try? await Task.sleep(nanoseconds: 700_000_000)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds,to: rep)
        try? rep.representation(using: .png,properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
