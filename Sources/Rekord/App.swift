import SwiftUI
import AppKit
import UserNotifications
import RecorderCore

@main struct RekordApp: App {
    @StateObject private var store = EditorStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Rekord") {
            EditorView().environmentObject(store)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1100,minHeight: 740)
                .onAppear {
                    delegate.attach(store)
                    if !CommandLine.arguments.contains("--exit-after-diagnostics"),store.workspace == .record { store.updateMonitor() }
                }
                .onDisappear { store.suspendMonitor() }
        }
        .defaultSize(width: 1320,height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Projekt öffnen …") { store.openProject() }.keyboardShortcut("o").disabled(store.busy)
                Button("Projekt im Finder") { store.revealProject() }.disabled(store.directory == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Rückgängig") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo || store.busy)
                Button("Wiederholen") { store.redo() }.keyboardShortcut("z",modifiers: [.command,.shift]).disabled(!store.canRedo || store.busy)
            }
            CommandMenu("Aufnahme") {
                Button(store.hudActive ? "Aufnahme starten" : "Neue Aufnahme …") { if store.hudActive { store.prepareActiveSourceForStart(); store.startRecording() } else { store.openRecorder() } }.keyboardShortcut("1",modifiers: [.command,.shift]).disabled(store.phase != .idle)
                Button("Aufnahme stoppen") { store.stopRecording() }.keyboardShortcut("2",modifiers: [.command,.shift]).disabled(store.phase != .recording)
                Button(store.meetings.recording ? "Meeting stoppen" : "Meeting aufnehmen …") { if store.meetings.recording { store.meetings.stop() } else { store.meetings.requestStart() } }
                    .keyboardShortcut("m",modifiers: [.control,.option,.command]).disabled(store.busy || store.meetings.phase == .processing || store.meetings.phase == .starting)
                Button(store.paused ? "Aufnahme fortsetzen" : "Aufnahme pausieren") { store.togglePause() }.keyboardShortcut("p",modifiers: [.command,.shift]).disabled(store.phase != .recording)
                Button("Abspielen / Pause") { store.togglePlayback() }.keyboardShortcut(.space,modifiers: []).disabled(store.project == nil || store.busy)
                Button("An Abspielposition teilen") { store.split() }.keyboardShortcut("b").disabled(store.project == nil || store.busy)
                Button("Auswahl löschen") { store.deleteSelection() }.keyboardShortcut(.delete,modifiers: [.command]).disabled(store.project == nil || store.busy)
            }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var store: EditorStore?
    private var pendingOpen: URL?
    func attach(_ store: EditorStore) {
        self.store = store
        store.updateHotKeys()
        if let pendingOpen { self.pendingOpen = nil; store.open(pendingOpen) }
        if let pendingCommand { self.pendingCommand = nil; store.handleCommand(pendingCommand) }
    }
    private var globalStop: Any?
    private var ranDiagnostics = false
    func runDiagnosticsIfRequested() async {
        guard !ranDiagnostics else { return }; ranDiagnostics = true
        await Diagnostics.run(arguments: CommandLine.arguments)
        await LoomDiagnostics.run(arguments: CommandLine.arguments)
        await InterfaceDiagnostics.run(arguments: CommandLine.arguments)
        await PlaybackDiagnostics.run(arguments: CommandLine.arguments)
        await SnapshotDiagnostics.run(arguments: CommandLine.arguments)
        await ExportQueueDiagnostics.run(arguments: CommandLine.arguments)
        await LiveSnapshotDiagnostics.run(arguments: CommandLine.arguments)
        await RecorderFlowDiagnostics.run(arguments: CommandLine.arguments)
        await HardeningDiagnostics.run(arguments: CommandLine.arguments)
        await MeetingDiagnostics.run(arguments: CommandLine.arguments)
        await GuideDiagnostics.run(arguments: CommandLine.arguments)
        if CommandLine.arguments.contains("--exit-after-diagnostics") { NSApplication.shared.terminate(nil) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().delegate = self
        Task { await runDiagnosticsIfRequested() }
        globalStop = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains([.command,.shift]), event.charactersIgnoringModifiers == "2" {
                Task { @MainActor in self?.store?.stopRecording() }
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let store, !store.busy, store.exports.hasPending {
            let alert = NSAlert(); alert.messageText = "Export läuft noch"
            alert.informativeText = "Warte, bis die Exporte fertig sind, oder brich sie ab. Deine Originalaufnahmen bleiben erhalten."
            alert.addButton(withTitle: "Weiter exportieren"); alert.addButton(withTitle: "Exporte abbrechen")
            if alert.runModal() == .alertSecondButtonReturn { store.exports.cancelAll() }
            return .terminateCancel
        }
        if let store, store.meetings.phase != .idle {
            let alert = NSAlert(); alert.messageText = "Meeting läuft"
            alert.informativeText = "Stoppe das Meeting und warte, bis Transkript und Zusammenfassung fertig sind."
            alert.addButton(withTitle: "Zurück"); alert.runModal(); return .terminateCancel
        }
        guard let store, store.busy else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Aufnahme oder Export läuft"
        alert.informativeText = "Stoppe die Aufnahme oder brich den Export ab, bevor du die App beendest."
        alert.addButton(withTitle: "Zurück"); alert.runModal(); return .terminateCancel
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if url.scheme == "rekord" || url.scheme == "focusrecorder" {
            if let store { store.handleCommand(url) } else { pendingCommand = url }
            return
        }
        if let store { store.open(url) } else { pendingOpen = url }
    }
    private var pendingCommand: URL?
    /// „Transkript fertig“ notification → open that meeting.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["meeting"] as? String else { return }
        await MainActor.run {
            guard let store else { return }
            store.showMeetings(); store.meetings.reload(); store.meetings.selected = store.meetings.meetings.first { $0.path.hasPrefix(path) || path.hasPrefix($0.path) }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner,.sound] }
}
