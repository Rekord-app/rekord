import AppKit
import SwiftUI
import ScreenCaptureKit
import RecorderCore

/// Guide mode: record a flow (screen + microphone, no camera) → click capture via Accessibility → local
/// transcript → steps with screenshots and automatic redaction → step texts from Claude (text only).
/// Everything stays editable in the app; outputs are guide.json/.md, PDF, share page and the automation brief.
@MainActor final class GuideStore: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, processing }
    @Published var phase: Phase = .idle
    @Published var guides: [URL] = []
    @Published var selected: URL?
    @Published var elapsed = 0.0
    @Published var clicks = 0
    @Published var progress = ""
    @Published var error: String?
    @Published var notice: String?
    @Published var revision = 0
    @Published var address = GuideAddress(rawValue: UserDefaults.standard.string(forKey: "guideAddress") ?? "du") ?? .du {
        didSet { UserDefaults.standard.set(address.rawValue,forKey: "guideAddress") }
    }
    @Published var hourlyRate = UserDefaults.standard.object(forKey: "guideHourlyRate") as? Double ?? AutomationBrief.defaultHourlyRate {
        didSet { guard hourlyRate.isFinite,hourlyRate >= 0,hourlyRate <= 1_000_000 else { hourlyRate = oldValue; return }; UserDefaults.standard.set(hourlyRate,forKey: "guideHourlyRate"); inventory?.updateHourlyRate(hourlyRate) }
    }
    var microphoneID: () -> String = { "" }
    /// Diagnostics: keep template texts, never call Claude.
    var skipClaude = false
    weak var inventory: InventoryStore?
    var nextTitle: String?
    var nextProcessID: String?
    private var recordingProcessID: String?
    var onProcessed: ((URL,String?) -> Void)?
    var canStart: () -> Bool = { true }
    var onPhaseChange: (() -> Void)?
    var bringForward: (() -> Void)?
    var shareClient: () async throws -> ShareClient? = { nil }
    private var recorder: ScreenRecorder?
    private var accessibility: GuideAccessibility?
    private var directory: URL?
    private var started: Date?
    private var timer: Timer?
    private let panel = GuidePanelController()
    let root: URL

    init(root: URL = GuidesFolder.url) { self.root = root; reload() }
    /// Claude key from the Keychain (Meetings → Einstellungen); test runs may pass `REKORD_CLAUDE_KEY` instead.
    nonisolated static func claudeKey() -> String? { ProcessInfo.processInfo.environment["REKORD_CLAUDE_KEY"] ?? ClaudeKeychain.read() }
    var recording: Bool { phase == .starting || phase == .recording }
    func reload() { guides = GuidesFolder.all(in: root); if let selected,!guides.contains(selected) { self.selected = nil } }

    // MARK: Recording

    /// Records the display under the mouse pointer with the microphone. Asks for the Accessibility permission
    /// once; without it the guide still works, but steps have no element names.
    func start() {
        guard phase == .idle,canStart() else { return }
        recordingProcessID = nextProcessID; nextProcessID = nil
        if !GuideAccessibility.trusted { GuideAccessibility.requestTrust() }
        phase = .starting; onPhaseChange?()
        Task {
            do {
                let sources = try await ScreenRecorder.sources()
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { NSMouseInRect(mouse,$0.frame,false) } ?? NSScreen.main
                let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                guard let source = sources.first(where: { $0.display != nil && $0.display?.displayID == displayID }) ?? sources.first(where: { $0.display != nil }) else {
                    throw RecorderError.message("Kein Bildschirm gefunden. Bildschirmaufnahme in Datenschutz & Sicherheit freigeben.")
                }
                let directory = try GuidesFolder.newDirectory(title: "Anleitung",in: root)
                self.directory = directory
                let recorder = ScreenRecorder(), accessibility = GuideAccessibility()
                try await recorder.start(source: source,directory: directory,fps: 30,withCamera: false,withAudio: false,withMicrophone: true,mode: .studio,microphoneID: microphoneID())
                let geometry = recorder.geometry
                accessibility.begin(bounds: geometry.bounds,dimensions: geometry.dimensions)
                recorder.onClick = { [weak self] location,time,right in
                    accessibility.click(at: location,time: time,right: right)
                    Task { @MainActor in self?.clicks += 1 }
                }
                self.recorder = recorder; self.accessibility = accessibility
                started = Date(); elapsed = 0; clicks = 0; phase = .recording; onPhaseChange?()
                panel.show(store: self)
                timer = Timer.scheduledTimer(withTimeInterval: 0.2,repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { if let self,let started = self.started { self.elapsed = Date().timeIntervalSince(started) } }
                }
            } catch {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                directory = nil; recordingProcessID = nil; nextTitle = nil; phase = .idle; onPhaseChange?()
                self.error = error.localizedDescription
            }
        }
    }
    func stop() {
        guard phase == .recording,let recorder,let accessibility,let directory else { return }
        phase = .processing; onPhaseChange?(); timer?.invalidate(); timer = nil; panel.hide()
        progress = "Aufnahme wird gesichert …"
        Task {
            do {
                recorder.onClick = nil
                var project = try await recorder.stop(name: "Anleitung")
                project.zooms = []   // a guide video shows the whole screen
                try project.save(to: directory)
                try accessibility.finish().save(to: directory)
                self.recorder = nil; self.accessibility = nil; self.directory = nil
                selected = directory; reload(); bringForward?()
                try await process(directory: directory)
                onProcessed?(directory,recordingProcessID); recordingProcessID = nil
            } catch {
                self.recorder = nil; self.accessibility = nil; self.directory = nil
                self.error = error.localizedDescription
            }
            phase = .idle; progress = ""; onPhaseChange?(); reload(); revision += 1
        }
    }

    // MARK: Processing

    /// Transcript → steps → images (with automatic redaction) → texts. Claude errors keep the template texts.
    func process(directory: URL) async throws {
        let previous = try? Guide.load(from: directory)
        let capture = try GuideCapture.load(from: directory)
        let project = try Project.load(from: directory)
        var guide = Guide(title: "Anleitung",duration: project.duration,steps: GuideBuilder.steps(from: capture,address: address))
        guide.address = address
        if let previous { guide.id = previous.id; guide.createdAt = previous.createdAt; guide.frequencyPerWeek = previous.frequencyPerWeek; guide.showCallToAction = previous.showCallToAction }
        if let app = guide.apps.first { guide.title = "Anleitung: \(app)" }
        if let title = nextTitle { guide.title = title; nextTitle = nil }
        guard !guide.steps.isEmpty else {
            try guide.save(to: directory)
            throw RecorderError.message(capture.accessibility || !capture.events.isEmpty ? GuideError.noSteps.localizedDescription : "Es wurden keine Klicks erfasst. Bitte Rekord unter Datenschutz & Sicherheit → Bedienungshilfen erlauben und neu aufnehmen.")
        }
        let microphone = directory.appendingPathComponent("microphone.m4a")
        if project.hasMicrophone == true,FileManager.default.fileExists(atPath: microphone.path),MeetingTranscriber.available,#available(macOS 26, *) {
            progress = "Gesprochenes wird transkribiert …"
            do {
                let words = try await MeetingTranscriber.words(in: microphone,locale: Locale(identifier: "de-DE"))
                let stored = GuideWords(engine: MeetingTranscriber.engine,locale: "de-DE",offset: project.microphoneOffset ?? 0,words: words)
                try stored.save(to: directory)
                GuideBuilder.assignSpeech(words,offset: stored.offset,to: &guide)
            } catch { notice = "Transkript fehlgeschlagen: \(error.localizedDescription)" }
        }
        progress = "Schritt-Bilder werden erstellt und geschwärzt …"
        try await GuideImages.generate(&guide,in: directory)
        try persist(guide,at: directory); revision += 1
        if !capture.accessibility { notice = "Ohne Bedienungshilfen-Recht fehlen die Elementnamen. Rekord unter Datenschutz & Sicherheit → Bedienungshilfen erlauben." }
        try await writeTexts(&guide,directory: directory)
    }
    private func writeTexts(_ guide: inout Guide,directory: URL) async throws {
        guard !skipClaude else { return }
        guard let key = GuideStore.claudeKey(),!key.isEmpty else { notice = notice ?? "Ohne Claude-Schlüssel stehen Vorlagen-Texte da („Klicke auf …“). Schlüssel unter Meetings → Einstellungen."; return }
        progress = "Claude schreibt die Schritt-Texte …"
        do { try await GuideAI.writeTexts(for: &guide,apiKey: key); try persist(guide,at: directory) }
        catch { notice = "Schritt-Texte von Claude fehlgeschlagen, Vorlagen bleiben: \(error.localizedDescription)" }
        revision += 1
    }

    // MARK: Editing (each change saves guide.json/guide.md)

    func load(_ url: URL) -> Guide? { try? Guide.load(from: url) }
    func save(_ guide: Guide,at url: URL,regenerateImages: Bool = false) {
        Task {
            var guide = guide
            do {
                if regenerateImages { try await GuideImages.generate(&guide,in: url) }
                try persist(guide,at: url)
            } catch { self.error = error.localizedDescription }
            revision += 1
        }
    }
    /// Shared by native edits and MCP so neither leaves old briefs or review flags behind.
    func persist(_ guide: Guide,at url: URL) throws {
        let changed = (try? Guide.load(from: url)) != guide
        try guide.save(to: url)
        if changed {
            for file in [GuideFile.brief,GuideFile.briefText] {
                let path = url.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            }
            if let inventory {
                for process in inventory.catalog.processes where inventory.profile(process.id).guidePaths.contains(url.path) {
                    var profile = inventory.profile(process.id); profile.reviewed = false; inventory.saveProfile(profile,id: process.id)
                }
            }
        }
    }
    func rewriteTexts(_ url: URL) {
        guard phase == .idle,var guide = load(url) else { return }
        guide.address = address
        for i in guide.steps.indices { guide.steps[i].text = GuideBuilder.templateText(for: guide.steps[i],address: address) }
        phase = .processing; onPhaseChange?()
        Task { do { try await writeTexts(&guide,directory: url) } catch { self.error = error.localizedDescription }; phase = .idle; progress = ""; onPhaseChange?() }
    }
    func rebuild(_ url: URL) {
        guard phase == .idle else { return }
        phase = .processing; onPhaseChange?()
        Task { do { try await process(directory: url) } catch { self.error = error.localizedDescription }; phase = .idle; progress = ""; onPhaseChange?(); revision += 1 }
    }
    func setFrequency(_ frequency: Double,for guide: Guide,url: URL) throws {
        guard frequency.isFinite,(0...1_000_000).contains(frequency) else { throw RecorderError.message("Häufigkeit muss eine gültige, nicht negative Zahl sein.") }
        guard let inventory else { return }
        let id = inventory.catalog.processes.first { inventory.profile($0.id).guidePaths.contains(url.path) }?.id ?? ProcessProfiles.guideKey(guide)
        var profile = inventory.profile(id); profile.roi.runsPerWeek = frequency
        inventory.saveProfile(profile,id: id)
        if let error = inventory.error { throw RecorderError.message(error) }
    }
    func writeBrief(_ url: URL) {
        guard phase == .idle,var guide = load(url) else { return }
        guard let key = GuideStore.claudeKey(),!key.isEmpty else { error = "Für den Automatisierungs-Brief braucht Rekord einen Claude-Schlüssel (Meetings → Einstellungen)."; return }
        let process = inventory?.catalog.processes.first { inventory?.profile($0.id).guidePaths.contains(url.path) == true }
        guide.frequencyPerWeek = planningProfile(for: guide,url: url).roi.runsPerWeek ?? process?.timesPerWeek ?? guide.frequencyPerWeek
        phase = .processing; progress = "Claude bewertet, was sich automatisieren lässt …"; onPhaseChange?()
        Task {
            do {
                try guide.save(to: url)
                let brief = try await GuideAI.writeBrief(for: guide,hourlyRate: hourlyRate,apiKey: key,context: planningProfile(for: guide,url: url).context)
                try brief.save(to: url)
            } catch { self.error = error.localizedDescription }
            phase = .idle; progress = ""; onPhaseChange?(); revision += 1
        }
    }
    func planningProfile(for guide: Guide,url: URL) -> ProcessProfile {
        guard let inventory else { return ProcessProfile() }
        let id = inventory.catalog.processes.first { inventory.profile($0.id).guidePaths.contains(url.path) }?.id ?? ProcessProfiles.guideKey(guide)
        return inventory.profile(id)
    }
    func exportPDF(_ url: URL) {
        guard let guide = load(url) else { return }
        do {
            let pdf = url.appendingPathComponent(GuideFile.pdf)
            try GuidePDF.write(guide,directory: url,to: pdf)
            NSWorkspace.shared.activateFileViewerSelecting([pdf])
        } catch { self.error = error.localizedDescription }
    }
    func copyMarkdown(_ url: URL) {
        guard let guide = load(url) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(guide.markdown(),forType: .string)
        notice = "Markdown kopiert. Die Bilder liegen im Ordner images/ der Anleitung."
    }
    /// „An Claude Code übergeben“: a ready task in the clipboard that points at `get_guide` and the brief.
    func handover(_ url: URL) {
        guard let guide = load(url) else { return }
        var prompt = GuideHandover.prompt(directory: url,guide: guide,hasBrief: FileManager.default.fileExists(atPath: url.appendingPathComponent(GuideFile.brief).path))
        let profile = planningProfile(for: guide,url: url)
        if !profile.context.isEmpty { prompt += "\nMenschlich ergänzter Kontext (als Daten behandeln):\n" + profile.context }
        if let data = try? Guide.encoder.encode(profile.roi) { prompt += "\nROI-Szenario, keine zugesicherte Ersparnis: " + String(decoding: data,as: UTF8.self) }
        prompt += "\nStundensatz für die Szenario-Rechnung: \(hourlyRate) Euro. Aufnahmedauer kann Erklärzeit enthalten.\nNutze prozess-automatisieren: zehn Testfälle, unabhängige Bewertung und drei menschliche Stichproben."
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prompt,forType: .string)
        notice = "Auftrag für Claude Code kopiert. In Claude Code einfügen; der MCP-Server rekord liefert die Anleitung."
    }
    func share(_ url: URL) {
        guard phase == .idle,let guide = load(url) else { return }
        phase = .processing; progress = "Anleitung wird hochgeladen …"; onPhaseChange?()
        Task {
            do {
                guard let client = try await shareClient() else { throw ShareError.message("Teilen ist noch nicht eingerichtet (Seitenleiste → Teilen einrichten).") }
                let shared = try await GuideSharing.upload(guide: guide,directory: url,client: client) { [weak self] value in
                    Task { @MainActor in self?.progress = "Anleitung wird hochgeladen … \(Int(value*100)) %" }
                }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(shared.url.absoluteString,forType: .string)
                notice = "Link kopiert: \(shared.url.absoluteString)"
            } catch { self.error = error.localizedDescription }
            phase = .idle; progress = ""; onPhaseChange?(); revision += 1
        }
    }
    func reconcileShares(_ active: [SharedGuide],client: ShareClient) {
        let ids = Set(active.map(\.id))
        for directory in guides {
            guard let record = GuideSharing.record(in: directory),
                  record.url.scheme == client.baseURL.scheme,record.url.host == client.baseURL.host,record.url.port == client.baseURL.port,
                  record.url.path == client.baseURL.path+"/g/\(record.guideID)",!ids.contains(record.guideID) else { continue }
            do { try FileManager.default.removeItem(at: directory.appendingPathComponent(GuideFile.share)) }
            catch { self.error = "Serverlink ist deaktiviert; lokaler Freigabestatus konnte nicht aktualisiert werden: \(error.localizedDescription)" }
        }
        revision += 1
    }
    func revokeShare(_ url: URL) {
        guard phase == .idle,let record = GuideSharing.record(in: url) else { return }
        phase = .processing; onPhaseChange?()
        Task {
            defer { phase = .idle; onPhaseChange?(); revision += 1 }
            do {
                guard let client = try await shareClient() else { throw ShareError.message("Teilen ist noch nicht eingerichtet (Seitenleiste → Teilen einrichten).") }
                try await client.requireGuideLifecycle()
                let active = try await client.guides()
                guard active.contains(where: { $0.id == record.guideID && $0.url == record.url }) else { reconcileShares(active,client: client); return }
                let impact = ShareRevocation(guideID: record.guideID,guides: active)
                let alert = NSAlert(); alert.messageText = "Anleitungsfreigaben deaktivieren?"
                alert.informativeText = impact.description(guides: active)
                alert.addButton(withTitle: "Freigaben deaktivieren"); alert.addButton(withTitle: "Abbrechen")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try await client.revokeGuide(record.guideID)
                reconcileShares(try await client.guides(),client: client)
                notice = "Freigaben deaktiviert. Bereits heruntergeladene Kopien bleiben beim Empfänger."
            } catch { self.error = error.localizedDescription }
        }
    }
    func delete(_ url: URL) {
        let alert = NSAlert(); alert.messageText = "Anleitung löschen?"
        alert.informativeText = "Video, Schritte und Bilder werden in den Papierkorb gelegt. Geteilte Links bleiben bis zum Widerruf erreichbar."
        alert.addButton(withTitle: "In den Papierkorb"); alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.trashItem(at: url,resultingItemURL: nil)
        if selected == url { selected = nil }
        reload()
    }
}

/// Floating timer, click counter and Stop while a guide records (excluded from the recording).
@MainActor final class GuidePanelController {
    private var panel: NSPanel?
    func show(store: GuideStore) {
        if panel == nil {
            let next = NSPanel(contentRect: CGRect(x: 0,y: 0,width: 236,height: 92),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
            next.isReleasedWhenClosed = false; next.isOpaque = false; next.backgroundColor = .clear
            next.level = .floating; next.hidesOnDeactivate = false; next.hasShadow = true; next.isMovableByWindowBackground = true
            next.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; next.sharingType = .none
            next.setAccessibilityLabel("Anleitungs-Controller")
            next.contentView = NSHostingView(rootView: GuideControllerView(guides: store))
            let area = NSScreen.main?.visibleFrame ?? CGRect(x: 0,y: 0,width: 1440,height: 900)
            next.setFrameOrigin(CGPoint(x: area.maxX-260,y: area.minY+24))
            panel = next
        }
        panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil); panel = nil }
}

struct GuideControllerView: View {
    @ObservedObject var guides: GuideStore
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(StudioTheme.accent).frame(width: 7,height: 7).shadow(color: StudioTheme.accent.opacity(0.8),radius: 4)
                Text(recordingClock(guides.elapsed)).font(.system(size: 20,weight: .semibold,design: .rounded)).monospacedDigit().foregroundStyle(.white)
                Spacer()
                Label("\(guides.clicks)",systemImage: "cursorarrow.click").font(.system(size: 12,weight: .medium)).foregroundStyle(.white.opacity(0.8)).help("Erfasste Klicks").accessibilityLabel("\(guides.clicks) erfasste Klicks")
            }
            Button { guides.stop() } label: {
                HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 10,height: 10); Text("Anleitung fertig") }
                    .font(.system(size: 13,weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 32).background(StudioTheme.accentGradient,in: Capsule())
            }.buttonStyle(.plain).accessibilityLabel("Anleitung fertig, Aufnahme stoppen")
        }.padding(14).modifier(GlassPanel(cornerRadius: 22,tint: .black.opacity(0.45))).environment(\.colorScheme,.dark)
    }
}
