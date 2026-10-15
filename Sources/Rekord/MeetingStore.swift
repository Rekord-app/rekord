import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import RecorderCore

/// Meeting mode: one click records (microphone + system audio) → local transcript → Claude summary, all kept
/// inside Rekord. Settings (own name, glossary, Claude key) are per user so the app can be handed to colleagues.
@MainActor final class MeetingStore: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, processing }
    @Published var phase: Phase = .idle
    @Published var meetings: [URL] = []
    @Published var selected: URL?
    @Published var elapsed = 0.0
    @Published var microphoneLevel = 0.0
    @Published var systemLevel = 0.0
    @Published var progress = ""
    @Published var error: String?
    @Published var showSettings = false
    /// Changes whenever files of a meeting were rewritten, so detail views reload.
    @Published var revision = 0
    @Published var ownName = UserDefaults.standard.string(forKey: "meetingOwnName") ?? MeetingStore.defaultName {
        didSet { UserDefaults.standard.set(ownName,forKey: "meetingOwnName") }
    }
    @Published var glossary = UserDefaults.standard.string(forKey: "meetingGlossary") ?? "" {
        didSet { UserDefaults.standard.set(glossary,forKey: "meetingGlossary") }
    }
    @Published var hasAPIKey = false
    /// Record calls automatically when a meeting app starts using the microphone (no bot joins the call).
    @Published private(set) var autoRecord = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// App of the running call when it was picked up automatically.
    @Published var callApp: String?
    private var autoStarted = false
    private var detector: AnyObject?
    var microphoneID: () -> String = { "" }
    var onPhaseChange: (() -> Void)?
    var bringForward: (() -> Void)?
    private var recorder: MeetingRecorder?
    private var meeting: Meeting?
    private(set) var directory: URL?
    private var started: Date?
    private var timer: Timer?
    private let panel = MeetingPanelController()
    private lazy var menuBar = MeetingMenuBar(store: self)
    /// Floating timer/level controller during calls; off = only the red dot in the menu bar.
    @Published var showController = UserDefaults.standard.object(forKey: "meetingShowController") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showController,forKey: "meetingShowController") }
    }
    /// Controller shrunk to a small red dot for the running call (recording continues).
    @Published var controllerCompact = false
    func collapseController() { controllerCompact = true; if phase == .recording { panel.show(store: self,compact: true) } }
    func expandController() { controllerCompact = false; if phase == .recording { panel.show(store: self,compact: false) } }
    func showControllerPanel() { expandController() }
    private func updateIndicators() { menuBar.update() }
    let root: URL

    static var defaultName: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "Ich" }

    init(root: URL = MeetingsFolder.url,detect: Bool = false) {
        self.root = root
        MeetingRecordingPolicy.migrate(.standard)
        autoRecord = MeetingRecordingPolicy.enabled(.standard)
        reload()
        hasAPIKey = ClaudeKeychain.hasKey
        if detect { updateDetector() }
    }
    func explainMigrationIfNeeded() {
        guard phase == .idle,canStart(),!CommandLine.arguments.contains("--exit-after-diagnostics"),UserDefaults.standard.bool(forKey: "meetingMigrationNoticePending") else { return }
        UserDefaults.standard.set(false,forKey: "meetingMigrationNoticePending")
        let alert = NSAlert(); alert.messageText = "Automatische Meeting-Aufnahme ist jetzt aus"
        alert.informativeText = "Die frühere Einstellung wurde zurückgesetzt, damit kein Call ohne bewusste Aktivierung aufgenommen wird. Du kannst die Automatik in den Einstellungen wieder einschalten. Bestehende Aufnahmen bleiben erhalten."
        alert.addButton(withTitle: "Verstanden"); alert.runModal()
    }
    private func confirmRecording(automatic: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = automatic ? "Calls automatisch aufnehmen?" : "Meeting aufnehmen?"
        alert.informativeText = "Rekord nimmt Mikrofon und Systemton auf. Informiere die Beteiligten und kläre ihre Zustimmung vor der Aufnahme. Diese Bestätigung in Rekord ist kein Nachweis ihrer Zustimmung. Ton und Transkript bleiben lokal; eine Claude-Zusammenfassung sendet den Text mit deinem API-Schlüssel an Anthropic." + (automatic ? " Automatische Aufnahmen starten bei erkannten Calls, solange diese Einstellung aktiv ist. Du kannst sie jederzeit hier ausschalten." : "")
        alert.addButton(withTitle: automatic ? "Automatische Aufnahme aktivieren" : "Aufnahme starten"); alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func setAutoRecord(_ enabled: Bool) {
        guard phase == .idle else { error = "Diese Einstellung lässt sich nach der laufenden Aufnahme ändern."; return }
        if enabled && !confirmRecording(automatic: true) { return }
        MeetingRecordingPolicy.setEnabled(enabled,in: .standard)
        autoRecord = MeetingRecordingPolicy.enabled(.standard); updateDetector()
    }
    /// Starts or stops automatic call detection according to the setting.
    func updateDetector(testProcessName: String? = nil) {
        guard #available(macOS 14.2, *) else { return }
        let detector = (self.detector as? MeetingDetector) ?? MeetingDetector()
        self.detector = detector
        if let testProcessName { detector.testProcessName = testProcessName }
        detector.onStart = { [weak self] call in
            guard let self, self.autoRecord, self.phase == .idle, self.canStart() else { return }
            self.start(title: call.title == call.app ? "" : call.title,app: call.app,automatic: true)
        }
        detector.onEnd = { [weak self] _ in
            guard let self, self.autoStarted, self.phase == .recording else { return }
            self.stop(automatic: true)
        }
        if autoRecord || testProcessName != nil { detector.start() } else { detector.stop() }
    }
    /// The editor may be recording a screen video; a meeting must not start then.
    var canStart: () -> Bool = { true }
    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { self.error = "Autostart konnte nicht geändert werden: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
    var recording: Bool { phase == .starting || phase == .recording }
    var glossaryTerms: [String] { glossary.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    func reload() { meetings = MeetingsFolder.all(in: root); if let selected, !meetings.contains(selected) { self.selected = nil } }

    /// Hotkey and menu: starts recording right away, or stops a running meeting.
    func toggle() { recording ? stop() : requestStart() }
    func requestStart() { guard phase == .idle else { return }; bringForward?(); start() }
    /// Records microphone and system audio. Title, contact and company are filled from the summary after the call.
    func start(title: String = "",contact: String = "",company: String = "",app: String? = nil,automatic: Bool = false) {
        guard phase == .idle, canStart() else { return }
        guard #available(macOS 14.2, *) else { error = "Meeting-Aufnahmen benötigen macOS 14.2 oder neuer. Studio und lokale Dateien bleiben verfügbar."; return }
        if automatic { guard autoRecord && MeetingRecordingPolicy.enabled(.standard) else { return } }
        else if !confirmRecording(automatic: false) { return }
        let time = DateFormatter(); time.locale = Locale(identifier: "de_DE"); time.dateFormat = "HH:mm"
        var meeting = Meeting(title: title.isEmpty ? "\(app ?? "Meeting") \(time.string(from: Date()))" : title,contact: contact,company: company,consent: false,ownName: ownName.isEmpty ? Self.defaultName : ownName)
        meeting.app = app
        meeting.recordingConfirmedAt = automatic ? UserDefaults.standard.object(forKey: "meetingAutoRecordConfirmedAt") as? Date : Date()
        meeting.recordingConfirmationSource = automatic ? "automatic-opt-in-v2" : "manual-v2"
        autoStarted = automatic; callApp = app
        phase = .starting; onPhaseChange?()
        Task {
            do {
                let directory = try MeetingsFolder.newDirectory(for: meeting,in: root)
                self.directory = directory
                try meeting.save(to: directory)
                let recorder = MeetingRecorder()
                try await recorder.start(directory: directory,systemAudio: true,microphoneID: microphoneID())
                self.recorder = recorder; self.meeting = meeting; self.directory = directory
                started = Date(); elapsed = 0; phase = .recording; onPhaseChange?()
                controllerCompact = !showController; panel.show(store: self,compact: controllerCompact)
                updateIndicators()
                timer = Timer.scheduledTimer(withTimeInterval: 0.1,repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self,let started = self.started,let recorder = self.recorder else { return }
                        self.elapsed = Date().timeIntervalSince(started)
                        self.microphoneLevel = recorder.microphoneLevel; self.systemLevel = recorder.systemLevel
                    }
                }
                reload(); selected = directory
            } catch {
                if let directory = self.directory { try? FileManager.default.removeItem(at: directory) }
                phase = .idle; onPhaseChange?(); self.directory = nil; autoStarted = false; callApp = nil
                if automatic { ignoreDetectedCall(); notify("Call nicht aufgenommen",error.localizedDescription,nil) } else { self.error = error.localizedDescription }
            }
        }
    }
    /// `automatic`: the call ended (meeting app released the microphone). A manual stop during a detected call
    /// keeps that call from being picked up again.
    func stop(automatic: Bool = false) {
        guard phase == .recording,let recorder,var meeting,let directory else { return }
        if !automatic { ignoreDetectedCall() }
        let quiet = autoStarted; autoStarted = false; callApp = nil
        phase = .processing; onPhaseChange?(); timer?.invalidate(); timer = nil; panel.hide(); updateIndicators()
        progress = "Aufnahme wird gesichert …"
        Task {
            let stopped = Date()
            do {
                let result = try await recorder.stop()
                // A picked-up call shorter than 45 s is almost always a false trigger (mic test, voice note).
                if quiet, result.duration < 45 {
                    try? FileManager.default.removeItem(at: directory)
                    self.recorder = nil; self.meeting = nil; self.directory = nil
                    phase = .idle; progress = ""; onPhaseChange?(); reload(); revision += 1
                    return
                }
                meeting.duration = result.duration; meeting.microphoneOffset = result.microphoneOffset
                meeting.systemOffset = result.systemOffset; meeting.hasSystemAudio = result.hasSystemAudio
                meeting.error = result.warning
                meeting.status = .transcribing; try meeting.save(to: directory)
                self.recorder = nil; self.meeting = nil; self.directory = nil
                selected = directory; reload()
                if !quiet { bringForward?() }
                await process(directory: directory,meeting: meeting,since: stopped)
                if quiet, let done = try? Meeting.load(from: directory) {
                    notify(done.status == .failed ? "Call aufgenommen, Verarbeitung fehlgeschlagen" : "Transkript fertig",done.displayTitle,directory)
                }
            } catch {
                self.recorder = nil; self.meeting = nil; self.directory = nil
                if quiet {
                    // Automatically picked up but no sound at all (false trigger, locked screen): leave no empty entry.
                    try? FileManager.default.removeItem(at: directory)
                } else {
                    meeting.status = .failed; meeting.error = error.localizedDescription; try? meeting.save(to: directory)
                    self.error = error.localizedDescription
                }
            }
            phase = .idle; progress = ""; onPhaseChange?(); reload(); revision += 1
        }
    }
    /// Throws away the running take (wrongly detected call); the call is not picked up again.
    func discard() {
        guard phase == .recording,let recorder,let directory else { return }
        ignoreDetectedCall(); autoStarted = false; callApp = nil
        timer?.invalidate(); timer = nil; panel.hide(); updateIndicators(); phase = .processing; onPhaseChange?()
        Task {
            await recorder.abort()
            try? FileManager.default.removeItem(at: directory)
            self.recorder = nil; self.meeting = nil; self.directory = nil
            phase = .idle; onPhaseChange?(); reload()
        }
    }
    private func ignoreDetectedCall() { if #available(macOS 14.2, *) { (detector as? MeetingDetector)?.ignoreCurrent() } }
    /// macOS notification; clicking it opens the meeting (see `MeetingNotifications`).
    func notify(_ title: String,_ body: String,_ directory: URL?) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert,.sound]) { granted,_ in
            guard granted else { return }
            let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
            if let directory { content.userInfo = ["meeting": directory.path] }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,content: content,trigger: nil))
        }
    }
    /// Transcribe (unless a transcript exists) and summarize; also used to retry after an error.
    func process(directory: URL,meeting initial: Meeting,since start: Date = Date(),retranscribe: Bool = false) async {
        var meeting = initial
        // A recording warning (silent system track) stays visible; an earlier processing error does not.
        let warning = initial.status == .failed ? nil : initial.error
        do {
            var transcript = retranscribe ? nil : try? Transcript.load(from: directory)
            if transcript == nil && !MeetingTranscriber.available {
                meeting.status = .done; meeting.error = "Audio gesichert. Lokale Transkription ist auf diesem Mac nicht verfügbar (macOS 26 und unterstützte Hardware erforderlich)."
                try meeting.save(to: directory); revision += 1; return
            }
            if transcript == nil {
                progress = "Transkript wird erstellt …"; meeting.status = .transcribing; try meeting.save(to: directory); revision += 1
                let made = try await MeetingTranscriber.transcribe(directory: directory,meeting: meeting)
                try made.save(to: directory,meeting: meeting); transcript = made
                meeting.transcribedWith = made.engine
            }
            guard let transcript else { return }
            guard hasAPIKey else {
                meeting.status = .done; meeting.error = warning
                meeting.processingSeconds = (Date().timeIntervalSince(start)*10).rounded()/10
                try meeting.save(to: directory); revision += 1; return
            }
            progress = "Zusammenfassung wird erstellt …"; meeting.status = .summarizing; try meeting.save(to: directory); revision += 1
            guard !transcript.sentences.isEmpty else { throw RecorderError.message("Im Ton wurde keine Sprache erkannt. Mikrofon und Systemton prüfen.") }
            let summary = try await MeetingSummarizer.summarize(meeting: meeting,transcript: transcript,apiKey: ClaudeKeychain.read() ?? "",glossary: glossaryTerms)
            // Automatic call names from the conversation; placeholders („nicht angesprochen“) never become names.
            if MeetingSummary.isBlank(meeting.contact) || meeting.contact.lowercased().hasPrefix("nicht"), !MeetingSummary.isBlank(summary.contact) {
                meeting.contact = summary.contact.components(separatedBy: CharacterSet(charactersIn: ",(")).first?.trimmingCharacters(in: .whitespaces) ?? ""
            } else if meeting.contact.lowercased().hasPrefix("nicht") { meeting.contact = "" }
            if MeetingSummary.isBlank(meeting.company) || meeting.company.lowercased().hasPrefix("nicht"), !MeetingSummary.isBlank(summary.company) { meeting.company = summary.company }
            else if meeting.company.lowercased().hasPrefix("nicht") { meeting.company = "" }
            if let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { meeting.title = title }
            try summary.save(to: directory,meeting: meeting)
            meeting.summarizedWith = MeetingSummarizer.model
            meeting.status = .done; meeting.error = warning
            meeting.processingSeconds = (Date().timeIntervalSince(start)*10).rounded()/10
            try meeting.save(to: directory)
        } catch {
            meeting.status = .failed; meeting.error = [warning,error.localizedDescription].compactMap { $0 }.joined(separator: " · ")
            try? meeting.save(to: directory)
        }
        revision += 1
    }
    /// „Frag den Call“: answer from the transcript, kept in `questions.json`.
    @Published var asking: URL?
    func ask(_ url: URL,question: String) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty,asking == nil,let meeting = try? Meeting.load(from: url),let transcript = try? Transcript.load(from: url) else { return }
        asking = url; defer { asking = nil }
        do {
            let answer = try await MeetingSummarizer.ask(question: question,meeting: meeting,transcript: transcript,apiKey: ClaudeKeychain.read() ?? "")
            var items = MeetingQuestion.load(from: url); items.append(MeetingQuestion(question: question,answer: answer))
            try MeetingQuestion.save(items,to: url); revision += 1
        } catch { self.error = error.localizedDescription }
    }
    func retry(_ url: URL,retranscribe: Bool = false) {
        guard phase == .idle,let meeting = try? Meeting.load(from: url) else { return }
        phase = .processing; onPhaseChange?()
        Task { await process(directory: url,meeting: meeting,retranscribe: retranscribe); phase = .idle; progress = ""; onPhaseChange?(); reload() }
    }
    func delete(_ url: URL) {
        let alert = NSAlert(); alert.messageText = "Meeting löschen?"
        alert.informativeText = "Ton, Transkript und Zusammenfassung werden in den Papierkorb gelegt."
        alert.addButton(withTitle: "In den Papierkorb"); alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.trashItem(at: url,resultingItemURL: nil)
        if selected == url { selected = nil }
        reload()
    }
    func saveAPIKey(_ key: String) {
        do { try ClaudeKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); hasAPIKey = ClaudeKeychain.hasKey }
        catch { self.error = error.localizedDescription }
    }
}

/// Claude API key in the login Keychain (same handling as the share token: read once per app run).
enum ClaudeKeychain {
    private static let service = "dev.sapunov.Rekord.claude", account = "api.anthropic.com"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: String?
    /// Only checks that the item exists. Reading attributes needs no access to the secret, so a new build does
    /// not show the Keychain password dialog at launch; that dialog appears at most once, on the first summary.
    static var hasKey: Bool {
        if let env = ProcessInfo.processInfo.environment["REKORD_CLAUDE_KEY"] { return !env.isEmpty }
        if let cached = lock.withLock({ cache }) { return !cached.isEmpty }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,kSecAttrService as String: service,kSecAttrAccount as String: account,
                                    kSecReturnAttributes as String: true,kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary,nil) == errSecSuccess
    }
    static func read() -> String? {
        // Test builds and diagnostics pass the key in the environment, so a differently signed build never
        // triggers the Keychain password dialog (the item is bound to the exact cdhash). Empty = no key.
        if let env = ProcessInfo.processInfo.environment["REKORD_CLAUDE_KEY"] { return env.isEmpty ? nil : env }
        if let cached = lock.withLock({ cache }) { return cached }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,kSecAttrService as String: service,kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess,let data = result as? Data,let key = String(data: data,encoding: .utf8) else { return nil }
        lock.withLock { cache = key }
        return key
    }
    static func save(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,kSecAttrService as String: service,kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        lock.withLock { cache = nil }
        guard !key.isEmpty else { return }
        var item = query; item[kSecValueData as String] = Data(key.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw RecorderError.message("Claude-Schlüssel konnte nicht im Schlüsselbund gespeichert werden.") }
        lock.withLock { cache = key }
    }
}
