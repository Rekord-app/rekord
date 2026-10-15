import AppKit
import SwiftUI
import AVFoundation
import RecorderCore
import UniformTypeIdentifiers

enum CaptureMode: String, CaseIterable { case display, window, area }

@MainActor final class EditorStore: ObservableObject {
    enum Phase { case idle, preparing, recording, stopping, exporting, uploading }
    enum Workspace { case record, edit, meetings, guides, inventory }
    @Published var workspace: Workspace = .record
    @Published var sourcesLoading = false
    @Published var recordingStyle = Style()
    @Published var inspectorTab = InspectorTab.appearance
    let monitor = CaptureMonitor()
    /// Meeting mode (audio-only call notes) lives beside Studio and Loom.
    let meetings: MeetingStore
    /// Guide mode (step-by-step guides from a narrated screen recording).
    let guides: GuideStore
    let inventory: InventoryStore
    let exports = ExportQueue()
    private let recordingPanel = RecordingPanelController()
    private var monitorTask: Task<Void,Never>?
    let shareActivity = ShareActivityStore()
    @Published var showVideoOffers = false
    @Published var showOfferSetup = false
    var pendingOfferShare: URL?
    @Published var offerVideo: SharedVideo?
    @Published var showShareSettings = false
    @Published var shareConfigured = !(UserDefaults.standard.string(forKey: "shareServer") ?? "").isEmpty
    @Published var shareReceipt: ShareReceipt?
    var shareTask: Task<Void,Never>?
    @Published var project: Project?
    @Published var directory: URL?
    @Published var sources: [CaptureSource] = []
    @Published var selectedSource = ""
    /// Floating recorder (toolbar, camera bubble, on-screen selection) instead of the main window.
    @Published var hudActive = false { didSet { updateHotKeys() } }
    @Published var captureMode: CaptureMode = .display
    @Published var areaSource: CaptureSource?
    weak var mainWindow: NSWindow?
    private lazy var hud = RecorderHUDController(store: self)
    var recorderHUD: RecorderHUDController { hud }
    /// What Start records: the chosen area, or the selected display/window.
    var activeSource: CaptureSource? { captureMode == .area ? areaSource : sources.first(where: { $0.id == selectedSource }) }
    @Published var phase: Phase = .idle { didSet { updateHotKeys(); if phase != .idle { inventory.checkIn.cancel() } } }
    @Published var recordingTitle = ""
    @Published var recordingMode: RecordingMode = .studio
    @Published var withMicrophone = false
    @Published var withCamera = false
    @Published var withAudio = true
    @Published var cameraID = UserDefaults.standard.string(forKey: "cameraDevice") ?? ""
    @Published var microphoneID = UserDefaults.standard.string(forKey: "microphoneDevice") ?? ""
    @Published var cameras: [CaptureDeviceOption] = []
    @Published var microphones: [CaptureDeviceOption] = []
    @Published var captureFPS = 60
    @Published var sourceTime = 0.0
    @Published var editedTime = 0.0
    /// Still frame shown only while the playhead sits in a removed source range (not part of the video).
    @Published var removedFrame: CGImage?
    @Published var playerReady = false
    let player = AVPlayer()
    @Published var playing = false
    @Published var selectedCut: UUID?
    /// Camera or microphone failure during the running take (screen keeps recording).
    @Published var trackProblem: String?
    /// Outcome of the last rekord:// command, reported in status.json.
    var lastCommand: [String: Any]?
    @Published var selectedZoom: UUID? { didSet { if selectedZoom != nil { selectedLayout = nil } } }
    @Published var selectedLayout: UUID? { didSet { if selectedLayout != nil { selectedZoom = nil } } }
    @Published var error: String?
    @Published var status = "Bereit für deine erste Aufnahme"
    @Published var elapsed = 0.0
    @Published var paused = false
    private var pausedTotal = 0.0
    private var pauseStarted: Date?
    @Published var exportProgress = 0.0
    @Published var exportHeight = 1080
    @Published var exportFPS = 30
    @Published var recent: [URL] = []
    /// Every recording in the recordings folder and its user folders, plus opened takes from elsewhere (archive).
    @Published var library: [URL] = []
    /// User folders in the recordings folder.
    @Published var folders: [URL] = []
    /// Folder shown in the library; nil = all recordings.
    @Published var folderFilter: String?
    private var recorder: ScreenRecorder?
    private var pendingDirectory: URL?
    /// Take being recorded right now (never moved by the storage cleanup).
    var recordingDirectory: URL? { pendingDirectory }
    private var pendingMode: RecordingMode = .studio
    private var pendingTitle = ""
    private var pendingStyle = Style()
    let captureRoot: URL?
    private let previewEngine = PreviewEngine()
    private var previewRevision = 0
    private var previewRunning = false
    private var timer: Timer?
    private var recordingStart: Date?
    private var timeline: PlaybackTimeline?
    private var timelineKey: TimelineKey?
    private var timelineTask: Task<Void,Never>?
    private var rebuilding = false
    private var timeObserver: Any?
    private var seekTarget: CMTime?
    private var seeking = false
    private var exportTask: Task<Void,Never>?
    private var history: [Project] = []
    private var future: [Project] = []
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var busy: Bool { phase != .idle || countdown != nil }
    /// 3-2-1 before recording starts (shown large on screen, never captured).
    @Published var countdown: Int?
    /// Whole-display MacBook recordings are cropped to 16:9 without menu bar and Dock (reversible in the editor).
    @Published var autoWidescreen = UserDefaults.standard.object(forKey: "autoWidescreen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoWidescreen,forKey: "autoWidescreen") }
    }
    @Published var countdownEnabled = UserDefaults.standard.object(forKey: "countdown") as? Bool ?? true {
        didSet { UserDefaults.standard.set(countdownEnabled,forKey: "countdown") }
    }
    private var countdownTask: Task<Void,Never>?
    private let countdownHUD = CountdownHUDController()
    /// `meetingsRoot`/`guidesRoot`: diagnostics render synthetic meetings and guides from a temporary folder,
    /// so the user's own calls and guides are never shown or touched.
    init(captureRoot: URL? = nil,meetingsRoot: URL? = nil,guidesRoot: URL? = nil) {
        self.captureRoot = captureRoot
        meetings = MeetingStore(root: meetingsRoot ?? MeetingsFolder.url,detect: !CommandLine.arguments.contains("--exit-after-diagnostics"))
        guides = GuideStore(root: guidesRoot ?? GuidesFolder.url)
        inventory = InventoryStore()
        if !CommandLine.arguments.contains("--exit-after-diagnostics"), RecordingsFolder.migrateLegacy() {
            UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []).map(RecordingsFolder.migratedPath),forKey: "recentProjects")
        }
        recent = (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []).map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) && !Library.isTemporary($0) }
        if !CommandLine.arguments.contains("--exit-after-diagnostics") { UserDefaults.standard.set(recent.map(\.path),forKey: "recentProjects") }
        refreshLibrary()
        // Takes interrupted by a crash or power loss become normal projects again.
        if !CommandLine.arguments.contains("--exit-after-diagnostics") {
            let folder = captureRoot ?? RecordingsFolder.url
            Task { @MainActor [weak self] in
                let rescued = await RecoveryJournal.repairIncomplete(in: folder)
                guard let self, !rescued.isEmpty else { return }
                self.recent = rescued+self.recent.filter { !rescued.contains($0) }
                UserDefaults.standard.set(self.recent.map(\.path),forKey: "recentProjects")
                self.status = rescued.count == 1 ? "Eine abgebrochene Aufnahme wurde gerettet" : "\(rescued.count) abgebrochene Aufnahmen wurden gerettet"
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1/20,repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        player.actionAtItemEnd = .pause
        // Local media: start immediately instead of buffering against network stalls.
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1,timescale: 30),queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerAdvanced(to: time) }
        }
        refreshDevices()
        meetings.microphoneID = { [weak self] in self?.microphoneID ?? "" }
        meetings.onPhaseChange = { [weak self] in self?.updateHotKeys(); self?.objectWillChange.send(); self?.meetings.explainMigrationIfNeeded(); if self?.meetings.phase != .idle { self?.inventory.checkIn.cancel() } }
        meetings.bringForward = { [weak self] in self?.showMeetings() }
        meetings.canStart = { [weak self] in self.map { !$0.busy && $0.guides.phase == .idle } ?? true }
        // Login startup is an explicit setting, never enabled as a side effect of first launch.
        inventory.pauseReason = { [weak self] in
            guard let self else { return "manual" }
            return self.busy || self.meetings.recording || self.guides.recording ? "meeting" : nil
        }
        inventory.canAsk = { [weak self] in
            guard let self else { return false }
            return !self.busy && self.meetings.phase == .idle && self.guides.phase == .idle && !InventoryRecorder.locked && !InventoryRecorder.idle && !InventoryPresentation.isFullscreen
        }
        inventory.bringForward = { [weak self] in self?.showInventory() }
        inventory.onChange = { [weak self] in self?.writeStatus() }
        inventory.hourlyRate = { [weak self] in self?.guides.hourlyRate ?? 50 }
        inventory.activate()
        guides.microphoneID = { [weak self] in self?.microphoneID ?? "" }
        guides.onPhaseChange = { [weak self] in self?.updateHotKeys(); self?.objectWillChange.send(); if self?.guides.phase != .idle { self?.inventory.checkIn.cancel() } }
        guides.bringForward = { [weak self] in self?.showGuides() }
        guides.shareClient = { [weak self] in (self?.shareConfigured ?? false) ? try? self?.shareClient() : nil }
        for name in [AVCaptureDevice.wasConnectedNotification,AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name,object: nil,queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let before = (self.cameraID,self.microphoneID)
                    self.refreshDevices()
                    if before != (self.cameraID,self.microphoneID) || self.phase == .idle { self.devicesChanged() }
                }
            }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,object: nil,queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,(note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.playing = false
            }
        }
    }
    func requestCameraIfNeeded() {
        updateMonitor()
    }
    var liveStyle: Style {
        var style = recordingStyle
        if recordingMode == .loom { style = Style(); style.padding = 0; style.cornerRadius = 0; style.shadow = 0 }
        style.showCamera = withCamera
        return style
    }
    func updateMonitor() {
        let previous = monitorTask; previous?.cancel()
        monitorTask = Task {
            await previous?.value
            await monitor.stop()
            guard !Task.isCancelled,workspace == .record || hudActive,phase == .idle else { return }
            do {
                // The floating recorder shows the camera bubble and meter only; no screen preview is needed there.
                try await monitor.start(source: hudActive ? nil : sources.first(where: { $0.id == selectedSource }),camera: withCamera,microphone: withMicrophone,cameraID: cameraID,microphoneID: microphoneID,mode: recordingMode,style: liveStyle)
            } catch is CancellationError { }
            catch { await monitor.stop(); monitor.showError(error.localizedDescription) }
        }
    }
    func showRecordingSetup() { guard !busy else { return }; pause(); workspace = .record; updateMonitor() }
    /// Opens the floating recorder; the main window steps back until recording ends or the recorder is closed.
    func openRecorder() {
        guard !busy, !hudActive, meetings.phase == .idle, guides.phase == .idle else { return }
        pause(); hudActive = true
        if sources.isEmpty { refreshSources() }
        mainWindow?.orderOut(nil)
        hud.open(); updateMonitor()
    }
    func closeRecorder() {
        guard hudActive, phase == .idle, countdown == nil else { return }
        hudActive = false; hud.close(); updateMonitor(); bringMainWindowForward()
    }
    /// Global shortcuts: Esc while the recorder is open, ⌘⇧2 / ⌘⇧P while recording.
    func updateHotKeys() {
        HotKeys.shared.perform = { [weak self] action in
            guard let self else { return }
            switch action {
            case .escape: if self.countdown != nil { self.cancelCountdown() } else if self.phase == .idle { self.closeRecorder() }
            case .stop: if self.meetings.recording { self.meetings.stop() } else if self.guides.recording { self.guides.stop() } else { self.stopRecording() }
            case .meeting: if self.meetings.recording { self.meetings.stop() } else if !self.busy { self.meetings.requestStart() }
            case .pause: self.togglePause()
            }
        }
        writeStatus()
        HotKeys.shared.set(.escape,enabled: hudActive && phase == .idle)
        HotKeys.shared.set(.stop,enabled: phase == .recording || meetings.phase == .recording || guides.phase == .recording)
        HotKeys.shared.set(.meeting,enabled: true)
        HotKeys.shared.set(.pause,enabled: phase == .recording)
    }
    func bringMainWindowForward() {
        mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    /// In display mode the display under the pointer is recorded ; window/area come from on-screen selection.
    func prepareActiveSourceForStart() {
        guard captureMode == .display else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let source = sources.first(where: { $0.display?.displayID == number.uint32Value }) else { return }
        selectedSource = source.id
    }
    /// Meetings workspace in the main window (closes an idle floating recorder first).
    func showMeetings() {
        guard !busy else { return }
        if hudActive { closeRecorder() }
        pause(); workspace = .meetings; updateMonitor(); bringMainWindowForward()
    }
    /// Guides workspace in the main window.
    func showGuides() {
        guard !busy else { return }
        if hudActive { closeRecorder() }
        pause(); workspace = .guides; updateMonitor(); bringMainWindowForward()
    }
    func showInventory() {
        guard !busy else { return }; if hudActive { closeRecorder() }
        pause(); workspace = .inventory; updateMonitor(); bringMainWindowForward()
    }
    func showEditor() { guard !busy,project != nil else { return }; workspace = .edit; updateMonitor() }
    func suspendMonitor() {
        guard !busy else { return }
        let previous = monitorTask; previous?.cancel()
        monitorTask = Task { await previous?.value; await monitor.stop() }
    }
    /// Lists cameras/microphones and drops a remembered device that is no longer connected.
    func refreshDevices() {
        cameras = CaptureDevices.cameras(); microphones = CaptureDevices.microphones()
        if !cameraID.isEmpty, !cameras.contains(where: { $0.id == cameraID }) { cameraID = "" }
        if !microphoneID.isEmpty, !microphones.contains(where: { $0.id == microphoneID }) { microphoneID = "" }
    }
    func devicesChanged() {
        UserDefaults.standard.set(cameraID,forKey: "cameraDevice"); UserDefaults.standard.set(microphoneID,forKey: "microphoneDevice")
        updateMonitor()
    }
    var defaultCameraName: String { CaptureDevices.camera(id: "")?.localizedName ?? "keine Kamera" }
    var defaultMicrophoneName: String { CaptureDevices.microphone(id: "")?.localizedName ?? "kein Mikrofon" }
    func chooseMode(_ mode: RecordingMode) {
        recordingMode = mode
        captureFPS = mode == .studio ? 60 : 30
        if mode == .loom { withMicrophone = true }
        updateMonitor()
    }
    func refreshSources() {
        guard phase == .idle,!sourcesLoading else { return }
        sourcesLoading = true
        status = "Aufnahmequellen werden geladen …"
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        Task {
            defer { sourcesLoading = false }
            do {
                sources = try await ScreenRecorder.sources()
                if !sources.contains(where: { $0.id == selectedSource }) { selectedSource = sources.first?.id ?? "" }
                status = "\(sources.count) Aufnahmequellen verfügbar"
                updateMonitor()
            } catch { self.error = "Bildschirmzugriff fehlt oder Quelle nicht verfügbar. Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme öffnen und Rekord freigeben.\n\n\(error.localizedDescription)"; status = "Bildschirmfreigabe prüfen" }
        }
    }
    func startRecording() {
        guard phase == .idle, countdown == nil, !sourcesLoading, activeSource != nil else { return }
        guard countdownEnabled, !CommandLine.arguments.contains("--exit-after-diagnostics") else { beginRecording(); return }
        countdownTask = Task {
            if hudActive { hud.overlays.update(store: self) }
            for count in [3,2,1] {
                countdown = count; countdownHUD.show(count)
                try? await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
            }
            countdown = nil; countdownHUD.hide(); countdownTask = nil
            beginRecording()
        }
    }
    func cancelCountdown() {
        countdownTask?.cancel(); countdownTask = nil; countdown = nil; countdownHUD.hide()
        if hudActive { hud.overlays.update(store: self) }
    }
    private func beginRecording() {
        guard phase == .idle,!sourcesLoading, let source = activeSource else { return }
        pause(); workspace = .record; pendingMode = recordingMode; pendingStyle = liveStyle; pendingTitle = recordingTitle.trimmingCharacters(in: .whitespacesAndNewlines); phase = .preparing; status = "Aufnahme wird vorbereitet …"
        let preparingMonitor = monitorTask; preparingMonitor?.cancel()
        Task {
            do {
                await preparingMonitor?.value
                await monitor.stop(clear: false)
                let root = captureRoot ?? RecordingsFolder.url
                let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
                let dir = root.appendingPathComponent("Aufnahme \(stamp.string(from: Date()))-\(UUID().uuidString.prefix(4)).\(ProjectFolder.fileExtension)")
                try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
                pendingDirectory = dir
                let recorder = ScreenRecorder()
                recorder.onUnexpectedStop = { [weak self] message in Task { @MainActor in
                    guard let self, self.phase == .recording else { return }
                    self.error = "Aufnahmequelle wurde unterbrochen: \(message)"; self.stopRecording()
                } }
                recorder.onTrackProblem = { [weak self] message in Task { @MainActor in
                    guard let self, self.phase == .recording || self.phase == .preparing else { return }
                    self.status = "⚠︎ \(message)"; self.trackProblem = message
                } }
                var template = Project(name: pendingTitle.isEmpty ? dir.deletingPathExtension().lastPathComponent : pendingTitle,duration: 0,width: 2,height: 2)
                template.mode = pendingMode; template.style = pendingStyle; template.autoZoom = Self.rememberedAutoZoom
                recorder.recoveryTemplate = template
                trackProblem = nil
                self.recorder = recorder
                recorder.onPreview = monitor.receiver(mode: pendingMode,style: pendingStyle)
                let showsPanel = !CommandLine.arguments.contains("--exit-after-diagnostics") && !hudActive
                recorder.onCameraSession = { [weak self] session in
                    guard let self else { return }
                    self.monitor.showCamera(session: session)
                    if showsPanel { self.recordingPanel.show(store: self) }
                }
                try await recorder.start(source: source,directory: dir,fps: captureFPS,withCamera: withCamera,withAudio: withAudio,withMicrophone: withMicrophone,mode: pendingMode,cameraID: cameraID,microphoneID: microphoneID,widescreenMenuBar: autoWidescreen ? Self.menuBarShare(of: source) : nil)
                recordingStart = Date(); elapsed = 0; paused = false; pausedTotal = 0; pauseStarted = nil
                if hudActive { hud.overlays.update(store: self) }
                phase = .recording; status = "Aufnahme läuft · ⌘⇧2 zum Stoppen"
                if showsPanel { recordingPanel.show(store: self) }
            } catch { phase = .idle; recordingPanel.hide(); monitor.showCamera(session: nil); self.error = error.localizedDescription; status = "Aufnahmestart fehlgeschlagen"; recorder = nil; updateMonitor() }
        }
    }
    /// Height of the menu bar on the recorded display as a share of its height (notch displays: ~37 pt).
    static func menuBarShare(of source: CaptureSource) -> Double? {
        guard source.window == nil, source.area == nil, let display = source.display else { return nil }
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }), screen.frame.height > 0 else { return CropRect.menuBarShare }
        var bar = screen.frame.maxY-screen.visibleFrame.maxY
        if bar < 1 { bar = max(screen.safeAreaInsets.top,NSStatusBar.system.thickness) }   // menu bar set to hide automatically
        return Double(bar/screen.frame.height)
    }
    func stopRecording() {
        guard phase == .recording, let recorder, let dir = pendingDirectory else { return }
        phase = .stopping; status = "Aufnahme wird gespeichert …"; paused = false; pauseStarted = nil
        recordingPanel.hide(); monitor.showCamera(session: nil)
        Task {
            do {
                var project = try await recorder.stop(name: pendingTitle.isEmpty ? dir.deletingPathExtension().lastPathComponent : pendingTitle)
                project.mode = pendingMode
                project.style = pendingStyle
                project.style.crop = recorder.autoCrop
                let zoomSettings = Self.rememberedAutoZoom
                project.autoZoom = zoomSettings
                project.zooms = Motion.automaticZooms(pointer: project.pointer,duration: project.duration,settings: zoomSettings)
                if pendingMode == .loom {
                    project.zooms = []; project.style.padding = 0; project.style.cornerRadius = 0; project.style.shadow = 0
                }
                try project.save(to: dir)
                RecoveryJournal.finish(directory: dir)
                if pendingMode == .loom, recorder.quickShareReady {
                    try project.fingerprint().write(to: dir.appendingPathComponent("loom-project.txt"),atomically: true,encoding: .utf8)
                }
                self.recorder = nil; phase = .idle
                if hudActive { hudActive = false; hud.close(); bringMainWindowForward() }
                load(project: project,directory: dir)
                if let warning = recorder.warning {
                    status = "Teilaufnahme gesichert: \(warning)"
                    if warning.contains("ausgefallene Spuren") { self.error = "Aufnahme gesichert – aber nicht vollständig.\n\(warning)" }
                }
                else { status = "Aufnahme gespeichert · \(project.width)×\(project.height) · \(project.fps) fps" }
                if project.recordingMode == .loom { share() }
            } catch {
                self.recorder = nil; phase = .idle
                // The take could not be finished normally: rebuild it from the crash journal and the readable media.
                if let rescued = try? await RecoveryJournal.repair(dir) {
                    if hudActive { hudActive = false; hud.close(); bringMainWindowForward() }
                    load(project: rescued,directory: dir)
                    self.error = "Die Aufnahme ließ sich nicht normal abschließen und wurde gerettet (\(clock(rescued.duration))).\n\(error.localizedDescription)"
                    status = "Aufnahme gerettet"
                } else {
                    self.error = "\(error.localizedDescription)\nRohdaten: \(dir.path)"; status = "Aufnahme konnte nicht abgeschlossen werden"; updateMonitor()
                }
            }
        }
    }
    func openProject() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "Rekord-Aufnahme (.rekord) auswählen"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL) {
        do { try openProject(url) } catch { self.error = error.localizedDescription }
    }
    /// Opens a project or throws; on failure the previously open project stays as it was.
    func openProject(_ url: URL) throws {
        guard !busy else { throw ProjectError.message("Rekord ist gerade beschäftigt (Aufnahme oder Export).") }
        let dir = url.lastPathComponent == "project.json" ? url.deletingLastPathComponent() : url
        load(project: try Project.loadForEditing(from: dir),directory: dir)
    }
    func load(project: Project,directory: URL) {
        workspace = .edit; updateMonitor()
        exportFPS = project.defaultExportFPS
        pause(); self.project = project; self.directory = directory; history = []; future = []
        sourceTime = project.cuts.first?.start ?? 0; editedTime = 0; selectedCut = project.cuts.first?.id; selectedZoom = nil; selectedLayout = nil; removedFrame = nil
        timeline = nil; timelineKey = nil; playerReady = false; player.replaceCurrentItem(with: nil)
        // Test runs and snapshots open takes from temporary folders; those never enter the recent list.
        if !Library.isTemporary(directory) {
            recent.removeAll { $0 == directory }; recent.insert(directory,at: 0); recent = Array(recent.prefix(12))
            UserDefaults.standard.set(recent.map(\.path),forKey: "recentProjects")
        }
        refreshLibrary()
        loadShareReceipt(directory: directory)
        status = displayName; refreshPlayback(); noteSaved(); writeStatus()
    }
    /// Applies an edit on top of the newest saved state: if the MCP server (or another window) changed the project
    /// since we last read it, that version is loaded first, so neither side's change is lost.
    func edit(_ mutation: (inout Project) -> Void) {
        guard phase == .idle, let old = project else { return }
        guard let directory else {
            var next = old; mutation(&next)
            do { try next.validate(); history.append(old); future = []; project = next; refreshPlayback() } catch { self.error = error.localizedDescription }
            return
        }
        do {
            var merged = false
            for attempt in 0..<5 {
                let version = ProjectVersion.current(directory)
                var next = old
                if version != projectVersion { next = try Project.load(from: directory); merged = true }
                mutation(&next)
                do {
                    projectVersion = try next.save(to: directory,expecting: version)
                    history.append(old); if history.count > 100 { history.removeFirst() }; future = []
                    project = next; refreshPlayback()
                    if merged { status = "Mit Änderungen von außen zusammengeführt" }
                    return
                } catch ProjectError.conflict where attempt < 4 { continue }
            }
        } catch { self.error = error.localizedDescription }
    }
    /// Undo/redo change the visible state only after the file is saved, so screen and disk never disagree.
    func undo() {
        guard phase == .idle, let previous = history.last, let current = project else { return }
        pause()
        guard persist(previous) else { return }
        history.removeLast(); future.append(current); project = previous; refreshPlayback()
    }
    func redo() {
        guard phase == .idle, let next = future.last, let current = project else { return }
        pause()
        guard persist(next) else { return }
        future.removeLast(); history.append(current); project = next; refreshPlayback()
    }
    private func persist(_ state: Project) -> Bool {
        guard let directory else { return true }
        do { projectVersion = try state.save(to: directory,expecting: nil); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func seekSource(_ time: Double) {
        pause(); sourceTime = min(max(0,time),project?.duration ?? 0)
        guard let project else { return }
        var offset = 0.0, retained = false
        for cut in project.cuts {
            if sourceTime <= cut.end { editedTime = offset+max(0,sourceTime-cut.start); retained = sourceTime >= cut.start; break }
            offset += cut.duration; editedTime = offset
        }
        if retained { removedFrame = nil; seekPlayer(to: editedTime) }
        else { requestPreview() }
    }
    func seekEdited(_ time: Double) {
        pause(); editedTime = min(max(0,time),project?.editedDuration ?? 0); sourceTime = project?.sourceTime(at: editedTime) ?? 0
        removedFrame = nil; seekPlayer(to: editedTime)
    }
    /// Chases the latest requested time: one zero-tolerance seek at a time keeps scrubbing responsive.
    private func seekPlayer(to seconds: Double) {
        seekTarget = CMTime(seconds: seconds,preferredTimescale: 60000)
        guard !seeking else { return }
        chaseSeek()
    }
    private func chaseSeek() {
        guard let target = seekTarget, player.currentItem != nil else { seeking = false; return }
        seeking = true; seekTarget = nil
        player.seek(to: target,toleranceBefore: .zero,toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.chaseSeek() }
        }
    }
    func split() {
        guard project?.cuts.contains(where: { sourceTime > $0.start+0.05 && sourceTime < $0.end-0.05 }) == true else { return }
        pause(); edit { $0.split(at: sourceTime) }
        selectedCut = project?.cuts.first(where: { $0.start >= sourceTime-0.001 })?.id
    }
    func deleteCut() {
        guard let selectedCut, let project, project.cuts.count > 1 else { return }
        pause(); edit { $0.cuts.removeAll { $0.id == selectedCut } }; self.selectedCut = self.project?.cuts.first?.id
        seekEdited(min(editedTime,self.project?.editedDuration ?? 0))
    }
    func addZoom() {
        guard let project else { return }
        let start = min(sourceTime,max(0,project.duration-0.5)), end = min(project.duration,start+2.5)
        guard end-start >= 0.05 else { return }
        let zoom = ZoomSegment(start: start,end: end,focus: MotionTrack(samples: project.pointer,smoothing: 0.1).sample(at: start)?.position ?? .center)
        edit { $0.zooms.append(zoom) }; selectedZoom = zoom.id; inspectorTab = .zoom
    }
    /// Settings for click zooms; the last choice is remembered for new recordings.
    static var rememberedAutoZoom: AutoZoomSettings {
        get { (UserDefaults.standard.data(forKey: "autoZoomSettings").flatMap { try? JSONDecoder().decode(AutoZoomSettings.self,from: $0) }).flatMap { $0.valid ? $0 : nil } ?? .standard }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue),forKey: "autoZoomSettings") }
    }
    func removeAllZooms() { edit { $0.zooms = [] }; selectedZoom = nil; status = "Alle Zooms entfernt · ⌘Z macht es rückgängig" }
    func resetCuts() { edit { $0.cuts = [Cut(start: 0,end: $0.duration)] }; selectedCut = project?.cuts.first?.id; status = "Schnitte zurückgesetzt · ⌘Z macht es rückgängig" }
    /// Back to the raw take: no zooms, no cuts (pauses included), no camera layouts. Look, camera and cursor settings stay.
    func removeAllEdits() {
        edit { $0.zooms = []; $0.cuts = [Cut(start: 0,end: $0.duration)]; $0.cameraLayouts = nil }
        selectedZoom = nil; selectedLayout = nil; selectedCut = project?.cuts.first?.id
        status = "Alle Zooms, Schnitte und Kamera-Layouts entfernt · ⌘Z macht es rückgängig"
    }
    func removeAllCameraLayouts() { edit { $0.cameraLayouts = nil }; selectedLayout = nil; status = "Kamera-Layouts entfernt · ⌘Z macht es rückgängig" }
    /// Camera layout from the playhead: switches the segment under the playhead, otherwise adds one (3 s, up to the next segment).
    func addCameraLayout(_ layout: CameraLayout) {
        guard let project, project.hasCamera else { return }
        let t = min(sourceTime,max(0,project.duration-0.3)), segments = project.cameraLayouts ?? []
        if let current = segments.first(where: { $0.start <= t && t < $0.end }) {
            edit { p in if let i = p.cameraLayouts?.firstIndex(where: { $0.id == current.id }) { p.cameraLayouts?[i].layout = layout } }
            selectedLayout = current.id; inspectorTab = .camera; return
        }
        let next = segments.map(\.start).filter { $0 > t }.min() ?? project.duration
        let segment = CameraLayoutSegment(start: t,end: min(next,t+3),layout: layout)
        guard segment.end-segment.start >= 0.2 else { return }
        edit { $0.cameraLayouts = (($0.cameraLayouts ?? [])+[segment]).sorted { $0.start < $1.start } }
        selectedLayout = segment.id; inspectorTab = .camera
    }
    func setCameraLayout(_ id: UUID,_ layout: CameraLayout) {
        edit { p in if let i = p.cameraLayouts?.firstIndex(where: { $0.id == id }) { p.cameraLayouts?[i].layout = layout } }
    }
    func removeCameraLayout(_ id: UUID) {
        edit { p in p.cameraLayouts?.removeAll { $0.id == id }; if p.cameraLayouts?.isEmpty == true { p.cameraLayouts = nil } }
        if selectedLayout == id { selectedLayout = nil }
    }
    /// Removes the selected zoom or camera layout, otherwise the selected section.
    func deleteSelection() {
        if let id = selectedZoom, project?.zooms.contains(where: { $0.id == id }) == true {
            edit { $0.zooms.removeAll { $0.id == id } }; selectedZoom = nil
        } else if let id = selectedLayout, project?.cameraLayouts?.contains(where: { $0.id == id }) == true {
            removeCameraLayout(id)
        } else { deleteCut() }
    }
    func autoZoom(_ settings: AutoZoomSettings? = nil) {
        let settings = settings ?? project?.autoZoom ?? .standard
        Self.rememberedAutoZoom = settings
        edit { $0.autoZoom = settings; $0.zooms = Motion.automaticZooms(pointer: $0.pointer,duration: $0.duration,settings: settings) }
        selectedZoom = project?.zooms.first?.id
    }
    func togglePlayback() {
        guard let project, phase == .idle, playerReady, !rebuilding else { return }
        if playing { pause(); return }
        removedFrame = nil
        if editedTime >= project.editedDuration-0.05 { editedTime = 0; sourceTime = project.sourceTime(at: 0) }
        playing = true; seekTarget = nil
        // The paused frame is already at the playhead after scrubbing; only seek when it is not.
        if abs(player.currentTime().seconds-editedTime) < 0.5/Double(max(1,project.fps)) && !seeking { player.play(); return }
        player.seek(to: CMTime(seconds: editedTime,preferredTimescale: 60000),toleranceBefore: .zero,toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in guard finished,let self,self.playing else { return }; self.player.play() }
        }
    }
    func pause() { playing = false; player.pause() }
    private func playerAdvanced(to time: CMTime) {
        guard playing, let project, time.isNumeric else { return }
        editedTime = min(project.editedDuration,max(0,time.seconds))
        sourceTime = project.sourceTime(at: editedTime)
    }
    // MARK: Outside changes (Claude Code via MCP) and status for the MCP server

    /// Version of project.json this window last read or wrote.
    private var projectVersion: ProjectVersion?
    private var ticks = 0
    func noteSaved() { projectVersion = directory.flatMap(ProjectVersion.current) }
    /// The open take moved on disk (folder, rename of its folder): keep editing it under the new path.
    func relocateOpenProject(to target: URL) {
        guard project != nil else { return }
        directory = target
        timeline = nil; timelineKey = nil; playerReady = false; player.replaceCurrentItem(with: nil)
        loadShareReceipt(directory: target); refreshPlayback(); noteSaved(); writeStatus()
    }
    /// Closes the open take (e.g. before it goes to the Trash).
    func closeProject() {
        pause(); timelineTask?.cancel(); rebuilding = false
        player.replaceCurrentItem(with: nil); timeline = nil; timelineKey = nil; playerReady = false
        project = nil; directory = nil; projectVersion = nil; history = []; future = []; shareReceipt = nil; removedFrame = nil
        selectedCut = nil; selectedZoom = nil; selectedLayout = nil
        if workspace == .edit { workspace = .record }
        writeStatus()
    }
    /// Reloads the open project when another process (the MCP server) saved it; the previous state stays undoable.
    private func reloadIfChangedOutside() {
        guard phase == .idle, let directory, let current = project, let known = projectVersion, let version = ProjectVersion.current(directory), version != known,
              let next = try? Project.load(from: directory) else { return }
        projectVersion = version
        history.append(current); future = []
        project = next
        if !next.zooms.contains(where: { $0.id == selectedZoom }) { selectedZoom = nil }
        if next.cameraLayouts?.contains(where: { $0.id == selectedLayout }) != true { selectedLayout = nil }
        if !next.cuts.contains(where: { $0.id == selectedCut }) { selectedCut = next.cuts.first?.id }
        refreshPlayback(); status = "Von außen geändert und neu geladen · ⌘Z macht es rückgängig"
    }
    /// Small status file the MCP server reads (phase, recorder, open project).
    func writeStatus() {
        guard !CommandLine.arguments.contains("--exit-after-diagnostics") else { return }
        let folder = SupportFolder.url
        try? FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let phaseName: String = switch phase { case .idle: "idle"; case .preparing: "preparing"; case .recording: paused ? "paused" : "recording"; case .stopping: "stopping"; case .exporting: "exporting"; case .uploading: "uploading" }
        let status: [String: Any] = ["phase": phaseName,"recorder_open": hudActive,"countdown": countdown as Any,"recording_seconds": phase == .recording ? (elapsed*10).rounded()/10 : 0,
                                     "open_project": directory?.path as Any,"guide_phase": "\(guides.phase)","inventory_phase": inventory.phase.rawValue,"open_project_title": project == nil ? NSNull() : displayName,"updated": ISO8601DateFormatter().string(from: Date()),
                                     "last_command": lastCommand as Any]
        if let data = try? JSONSerialization.data(withJSONObject: status,options: [.prettyPrinted,.sortedKeys]) { try? data.write(to: folder.appendingPathComponent("status.json"),options: .atomic) }
    }
    /// rekord:// commands (focusrecorder:// still accepted) from the MCP server, scripts or other apps. Malformed
    /// commands are rejected with a readable error and never interrupt a recording. The outcome is reported in
    /// status.json (`last_command`) under the caller's id.
    func handleCommand(_ url: URL) {
        let command: AppCommand
        do { command = try AppCommand.parse(url) }
        catch { status = "Befehl abgelehnt: \(error.localizedDescription)"; reportCommand(id: nil,action: url.host ?? "",error: error.localizedDescription); return }
        switch command.action {
        case .inventory: showInventory(); reportCommand(command)
        case .inventoryPause: inventory.pause(minutes: command.minutes ?? 15); reportCommand(command)
        case .inventoryResume: inventory.resume(); reportCommand(command)
        case .open:
            guard let path = command.path else { openRecorder(); reportCommand(command); return }
            do { try openProject(path); bringMainWindowForward(); reportCommand(command) }
            catch { self.error = error.localizedDescription; reportCommand(command,error: error.localizedDescription) }
        case .start:
            guard phase == .idle else { reportCommand(command,error: "Es läuft bereits eine Aufnahme oder ein Export."); return }
            if !hudActive { openRecorder() }
            Task {
                for _ in 0..<100 where sources.isEmpty || sourcesLoading { try? await Task.sleep(nanoseconds: 100_000_000) }
                if command.source == .area169, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
                   let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                   let display = sources.first(where: { $0.display?.displayID == number.uint32Value })?.display {
                    let height = min(Double(display.height)-37,Double(display.width)*9/16)
                    captureMode = .area; areaSource = CaptureSource.area(CGRect(x: (Double(display.width)-height*16/9)/2,y: 37,width: height*16/9,height: height),on: display)
                } else { captureMode = .display; prepareActiveSourceForStart() }
                hud.overlays.update(store: self)
                startRecording()
                reportCommand(command)
            }
        case .stop:
            if meetings.recording { meetings.stop(); reportCommand(command); return }
            if guides.recording { guides.stop(); reportCommand(command); return }
            guard phase == .recording else { reportCommand(command,error: "Es läuft keine Aufnahme."); return }
            stopRecording(); reportCommand(command)
        case .pause:
            guard phase == .recording else { reportCommand(command,error: "Es läuft keine Aufnahme."); return }
            togglePause(); reportCommand(command)
        case .meetings:
            showMeetings(); meetings.reload()
            if let path = command.path?.path { meetings.selected = meetings.meetings.first { $0.path.hasPrefix(path) || path.hasPrefix($0.path) } }
            reportCommand(command)
        case .meeting:
            showMeetings(); if !meetings.recording { meetings.requestStart() }   // consent dialog always comes first
            reportCommand(command)
        case .guides:
            showGuides(); guides.reload()
            if let path = command.path?.path { guides.selected = guides.guides.first { $0.path.hasPrefix(path) || path.hasPrefix($0.path) } }
            reportCommand(command)
        case .guide:
            showGuides()
            guard guides.phase == .idle else { reportCommand(command,error: "Es läuft schon eine Anleitung."); return }
            guides.start(); reportCommand(command)
        case .guideStop:
            guard guides.recording else { reportCommand(command,error: "Es läuft keine Anleitung."); return }
            guides.stop(); reportCommand(command)
        case .meetingStop:
            guard meetings.recording else { reportCommand(command,error: "Es läuft kein Meeting."); return }
            meetings.stop(); reportCommand(command)
        case .share:
            // Share exactly the requested project or nothing: a missing, moved or broken project must never
            // fall back to the project that happens to be open.
            guard let path = command.path else { return }
            do {
                if directory.map({ ExportTarget.canonical($0).path }) != ExportTarget.canonical(path).path { try openProject(path) }
                guard let directory, ExportTarget.canonical(directory).path == ExportTarget.canonical(path).path else { throw ProjectError.message("Aufnahme konnte nicht geöffnet werden: \(path.path)") }
                guard phase == .idle else { throw ProjectError.message("Rekord ist gerade beschäftigt (Aufnahme oder Export).") }
                share(expected: directory,commandID: command.id)
                reportCommand(command)
            } catch { self.error = error.localizedDescription; reportCommand(command,error: error.localizedDescription) }
        }
    }
    /// Result of the last rekord:// command for status.json; `link` is set when a share finished.
    func reportCommand(_ command: AppCommand,error: String? = nil,link: String? = nil) {
        reportCommand(id: command.id,action: command.action.rawValue,error: error,link: link)
    }
    func reportCommand(id: String?,action: String,error: String? = nil,link: String? = nil,done: Bool? = nil) {
        var result: [String: Any] = ["action": action,"ok": error == nil,"at": ISO8601DateFormatter().string(from: Date())]
        if let id { result["id"] = id }
        if let error { result["error"] = error }
        if let link { result["link"] = link }
        result["done"] = done ?? (error != nil || action != "share")
        lastCommand = result; writeStatus()
    }
    private func tick() {
        ticks += 1
        if ticks % 20 == 0 { reloadIfChangedOutside(); if phase == .recording { writeStatus() } }
        if ticks % 1200 == 0 { cleanUpStorageIfDue() }   // checked every minute, runs at most once a day
        if ticks % 60 == 0, workspace == .record, phase == .idle { refreshLibrary() }   // picks up Finder changes
        if phase == .recording, let recordingStart {
            elapsed = Date().timeIntervalSince(recordingStart)-pausedTotal-(pauseStarted.map { Date().timeIntervalSince($0) } ?? 0)
        }
    }
    /// Throws the running take away (files deleted) and returns to the recorder.
    func discardRecording(then next: (() -> Void)? = nil) {
        guard phase == .recording, let recorder, let dir = pendingDirectory else { return }
        phase = .stopping; paused = false; pauseStarted = nil; status = "Aufnahme wird verworfen …"
        recordingPanel.hide()
        Task {
            await recorder.cancel()
            try? FileManager.default.removeItem(at: dir)
            self.recorder = nil; pendingDirectory = nil; phase = .idle; monitor.showCamera(session: nil)
            status = "Aufnahme verworfen"
            hud.overlays.update(store: self)
            updateMonitor()
            next?()
        }
    }
    /// Discards the take and starts a fresh one with the same source and devices.
    func restartRecording() { discardRecording { [weak self] in self?.startRecording() } }
    /// Pause or resume the running recording. Paused time is not recorded and is cut out on Stop.
    func togglePause() {
        guard phase == .recording, let recorder else { return }
        if paused {
            paused = false
            if let pauseStarted { pausedTotal += Date().timeIntervalSince(pauseStarted) }
            pauseStarted = nil; status = "Aufnahme läuft · ⌘⇧2 zum Stoppen"
            Task { await recorder.resume() }
        } else {
            paused = true; pauseStarted = Date(); status = "Pausiert · nichts wird aufgenommen"
            Task { await recorder.pause() }
        }
    }
    /// Rebuilds the edited composition when cuts change; look/zoom edits only swap the video composition.
    func refreshPlayback() {
        guard let project, let directory else { return }
        let key = TimelineKey(directory: directory,cuts: project.cuts,hasCamera: project.hasCamera,cameraOffset: project.cameraOffset,hasMicrophone: project.hasMicrophone,microphoneOffset: project.microphoneOffset)
        if let timeline, key == timelineKey, let item = player.currentItem {
            item.videoComposition = composition(timeline: timeline,project: project,directory: directory)
            if !playing { seekPlayer(to: editedTime) }
            return
        }
        timelineKey = key; timelineTask?.cancel(); pause(); rebuilding = true
        timelineTask = Task {
            defer { if !Task.isCancelled { rebuilding = false } }
            do {
                let next = try await PlaybackTimeline.make(project: project,directory: directory)
                guard !Task.isCancelled, self.directory == directory, let current = self.project else { return }
                let item = AVPlayerItem(asset: next.composition)
                item.audioMix = next.audioMix
                item.videoComposition = composition(timeline: next,project: current,directory: directory)
                timeline = next; pause()
                player.replaceCurrentItem(with: item); playerReady = true
                // Re-map the current source position: cut edits change where it sits in the edited video,
                // and the user may have scrubbed while the composition was rebuilding.
                seekSource(sourceTime)
            } catch is CancellationError {
            } catch {
                timelineKey = nil; status = "Vorschau: \(error.localizedDescription)"
            }
        }
    }
    private func composition(timeline: PlaybackTimeline,project: Project,directory: URL) -> AVVideoComposition {
        var background: CGImage?
        do { background = try BackgroundAsset.load(project: project,directory: directory) }
        catch { status = "Hintergrundbild: \(error.localizedDescription)" }
        return timeline.videoComposition(project: project,backgroundImage: background,height: 1080)
    }
    /// Removed ranges are not part of the edited composition; show them as a still from the original.
    func requestPreview() {
        previewRevision += 1
        guard !previewRunning, project != nil, directory != nil else { return }
        previewRunning = true
        Task {
            defer { previewRunning = false }
            while let project, let directory {
                let revision = previewRevision, time = sourceTime
                do {
                    let frame = try await previewEngine.frame(project: project,directory: directory,time: time)
                    if self.directory == directory, !playing, !(project.cuts.contains { time >= $0.start && time <= $0.end }) { removedFrame = frame }
                } catch { if !playing { status = "Vorschau: \(error.localizedDescription)" } }
                if revision == previewRevision { break }
            }
        }
    }
    private struct TimelineKey: Equatable {
        let directory: URL
        let cuts: [Cut]
        let hasCamera: Bool
        let cameraOffset: Double
        let hasMicrophone: Bool?
        let microphoneOffset: Double?
    }
    /// Readable title: the given name, or for unnamed takes the mode and recording time.
    var displayName: String {
        guard let project else { return "" }
        guard project.name.hasPrefix("Aufnahme "), let directory else { return project.name }
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let stamp = String(directory.deletingPathExtension().lastPathComponent.dropFirst(9).prefix(19))
        let mode = project.recordingMode == .loom ? "Loom-Aufnahme" : "Studio-Aufnahme"
        guard let date = parser.date(from: stamp) else { return mode }
        let display = DateFormatter(); display.locale = Locale(identifier: "de_DE"); display.setLocalizedDateFormatFromTemplate("dMMMHHmm")
        return "\(mode) · \(display.string(from: date))"
    }
    func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != displayName else { return }
        edit { $0.name = trimmed }
    }
    func revealProject() { if let directory { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
    /// Queues an MP4 export of the current state; editing and recording continue while it renders.
    func export() {
        guard phase == .idle || phase == .recording, let project, let directory else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = "\(project.name).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exports.enqueue(project: project,directory: directory,destination: url,height: exportHeight,fps: exportFPS)
        status = "Export eingereiht: \(url.lastPathComponent) · du kannst weiterarbeiten"
    }
    func cancelExport() { exportTask?.cancel(); cancelShare() }
}
