import AppKit
import SwiftUI
import RecorderCore

@MainActor final class InventoryStore: ObservableObject {
    enum Phase: String { case off, running, paused }
    @Published var phase: Phase = .off
    @Published var blocks: [InventoryBlock] = []
    @Published var catalog = ProcessCatalog()
    @Published var selectedDay = InventoryFolder.day()
    @Published var usage = ClaudeUsage()
    @Published var capturedSeconds = 0.0
    @Published var message = ""
    @Published var error: String?
    @Published var processing = false
    @Published var showSettings = false
    @Published var currentApp = ""
    @Published var currentPause: String?
    @Published var exclusions: String = UserDefaults.standard.string(forKey: "inventoryExclusions") ?? "" { didSet { saveSetting(exclusions,"Exclusions") } }
    @Published var questionsPerDay = UserDefaults.standard.object(forKey: "inventoryQuestions") as? Int ?? 8 { didSet { saveSetting(min(15,max(0,questionsPerDay)),"Questions") } }
    @Published var tokenBudget = UserDefaults.standard.object(forKey: "inventoryBudget") as? Int ?? 400000 { didSet { saveSetting(max(0,tokenBudget),"Budget") } }
    @Published var imageDays = UserDefaults.standard.object(forKey: "inventoryImageDays") as? Int ?? 7 { didSet { saveSetting(imageDays,"ImageDays") } }
    @Published var sampleDays = UserDefaults.standard.object(forKey: "inventorySampleDays") as? Int ?? 30 { didSet { saveSetting(sampleDays,"SampleDays") } }
    @Published var catalogHour = UserDefaults.standard.object(forKey: "inventoryCatalogHour") as? Int ?? 18 { didSet { saveSetting(catalogHour,"CatalogHour") } }
    @Published var catalogMinute = UserDefaults.standard.object(forKey: "inventoryCatalogMinute") as? Int ?? 30 { didSet { saveSetting(catalogMinute,"CatalogMinute") } }
    @Published var teamMode = UserDefaults.standard.bool(forKey: "inventoryTeam") { didSet { saveSetting(teamMode,"Team"); if teamMode && !consented { stop() } } }
    @Published var approved = Set<String>()
    @Published var exportEdits: [String: String] = [:]
    @Published var exportNames: [String: String] = [:]
    @Published var exportSteps: [String: String] = [:]
    var hourlyRate: () -> Double = { UserDefaults.standard.object(forKey: "guideHourlyRate") as? Double ?? 50 }
    var canAsk: () -> Bool = { true }, pauseReason: () -> String? = { nil }, bringForward: (() -> Void)?, onChange: (() -> Void)?
    let root: URL
    let recorder: InventoryRecorder
    lazy var checkIn = InventoryCheckInPanel()
    lazy var menu = InventoryMenuBar(store: self)
    private var timer: DispatchSourceTimer?, ticking = false
    private var resumeAt: Date?, lastSummary = Date.distantPast, nextQuestion = Date(), lastCleanup = ""
    private var lastQuestionActivity = 0.0
    private var postponedQuestion = false
    private let persistent: Bool
    private var consented: Bool { UserDefaults.standard.bool(forKey: "inventoryTeamConsentV1") }
    init(root: URL = InventoryFolder.url,persistent: Bool = true) {
        self.root = root; self.persistent = persistent; recorder = InventoryRecorder(root: root); reload()
    }
    private func saveSetting(_ value: Any,_ name: String) { if persistent { UserDefaults.standard.set(value,forKey: "inventory"+name) } }
    func activate() {
        guard persistent, !CommandLine.arguments.contains("--exit-after-diagnostics") else { return }
        if UserDefaults.standard.bool(forKey: "inventoryEnabled") {
            resumeAt = UserDefaults.standard.object(forKey: "inventoryResumeAt") as? Date
            if !teamMode || consented { start(); if let resumeAt,resumeAt > Date() { phase = .paused } }
        }
        cleanup()
    }
    func start() {
        if teamMode && !consented {
            let alert = NSAlert(); alert.messageText = "Arbeits-Inventur für dein Team"
            alert.informativeText = "Rekord erfasst lokal App, Fenster, URL und maskierten Text. Bilder bleiben auf deinem Mac. Maskierter Text geht zur Auswertung an Anthropic. Du kannst jederzeit pausieren und löschen. Dein Unternehmen erhält nur von dir geprüfte und freigegebene Prozesse, keine Zeitachse oder Bilder. Möchtest du selbst starten?"
            alert.addButton(withTitle: "Ich stimme zu und starte"); alert.addButton(withTitle: "Abbrechen")
            guard alert.runModal() == .alertFirstButtonReturn else { return }; saveSetting(true,"TeamConsentV1")
        }
        phase = .running; saveSetting(true,"Enabled"); menu.update()
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.sapunov.rekord.inventory-timer",qos: .utility))
        source.schedule(deadline: .now(),repeating: .seconds(5),leeway: .seconds(1))
        source.setEventHandler { [weak self] in Task { @MainActor in await self?.tick() } }; source.resume(); timer = source
        onChange?()
    }
    func pause(minutes: Int = 15) {
        guard phase != .off else { return }; phase = .paused; resumeAt = Date().addingTimeInterval(Double(minutes)*60); saveSetting(resumeAt!,"ResumeAt")
        checkIn.cancel(); menu.update(); onChange?(); Task { try? await recorder.flush() }
    }
    func pauseUntilTomorrow() { pause(minutes: max(1,Int((Calendar.current.nextDate(after: Date(),matching: DateComponents(hour: 8),matchingPolicy: .nextTime) ?? Date().addingTimeInterval(86400)).timeIntervalSinceNow/60))) }
    func resume() { resumeAt = nil; if persistent { UserDefaults.standard.removeObject(forKey: "inventoryResumeAt") }; start() }
    func stop() { timer?.cancel(); timer = nil; phase = .off; saveSetting(false,"Enabled"); checkIn.cancel(); menu.update(); onChange?(); Task { try? await recorder.flush() } }
    func tick() async {
        guard !ticking,phase != .off else { return }; ticking = true; defer { ticking = false }
        if phase == .paused,let resumeAt,Date() >= resumeAt { resume() }
        do {
            var reason = phase == .paused ? "manual" : pauseReason()
            if #available(macOS 14.2, *), MeetingDetector.activeCall() != nil { reason = "meeting" }
            let s = try await recorder.tick(paused: reason,exclusions: exclusions.components(separatedBy: .newlines).filter { !$0.isEmpty })
            currentPause = s.paused; currentApp = s.appName
            if s.paused == nil { capturedSeconds += s.seconds }
            if s.paused != nil || !canAsk() { checkIn.cancel() }
            menu.update(); onChange?(); cleanup()
            if Date().timeIntervalSince(lastSummary) >= 900, !processing { lastSummary = Date(); await summarize() }
            let parts = Calendar.current.dateComponents([.hour,.minute],from: Date())
            if (parts.hour ?? 0)*60+(parts.minute ?? 0) >= catalogHour*60+catalogMinute,
               UserDefaults.standard.string(forKey: "inventoryLastCatalog") != InventoryFolder.day(), !processing {
                await buildCatalog(); if error == nil { saveSetting(InventoryFolder.day(),"LastCatalog") }
            }
            if phase == .running, currentPause == nil, (postponedQuestion || capturedSeconds-lastQuestionActivity >= 1200),Date() >= nextQuestion { ask() }
        } catch { self.error = error.localizedDescription }
    }
    func reload() {
        blocks = (try? InventoryFile.read(root.appendingPathComponent(selectedDay).appendingPathComponent("blocks.json"))) ?? []
        catalog = (try? ProcessCatalog.load(root: root)) ?? ProcessCatalog()
        usage = (try? InventoryFile.read(InventoryFolder.directory(root: root).appendingPathComponent("usage.json"))) ?? ClaudeUsage()
        capturedSeconds = ((try? InventoryFile.samples(in: InventoryFolder.directory(root: root))) ?? []).filter { $0.paused == nil }.reduce(0) { $0+$1.seconds }
    }
    func checkIns(day: String? = nil) -> [InventoryCheckIn] { (try? InventoryFile.read(root.appendingPathComponent(day ?? InventoryFolder.day()).appendingPathComponent("checkins.json"))) ?? [] }
    func summarize() async {
        guard !processing else { return }; processing = true; defer { processing = false; reload() }
        do {
            try await recorder.flush()
            // Retry retained unsummarized days after missing key or exhausted daily budget.
            for day in InventoryFolder.days(in: root).sorted() {
            let dir = root.appendingPathComponent(day)
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("samples.jsonl").path) else { continue }
            let samples = (try? InventoryFile.samples(in: dir)) ?? []
            var pre = InventoryBuilder.preBlocks(samples: samples)
            let previous: [InventoryBlock] = (try? InventoryFile.read(dir.appendingPathComponent("blocks.json"))) ?? []
            for i in pre.indices { if let old = previous.first(where: { $0.id == pre[i].id && $0.end == pre[i].end && $0.summarized }) { pre[i] = old } }
            let todo = pre.filter { !$0.summarized }
            // Save local blocks even without a key/budget. Retry them at the next interval.
            try InventoryFile.write(pre,to: dir.appendingPathComponent("blocks.json"))
            if !todo.isEmpty {
                let summarized = try await InventoryAI.summarizeBlocks(preBlocks: todo,samples: samples,checkIns: checkIns(day: day),existingProcesses: catalog.processes,root: root,budget: tokenBudget,apiKey: GuideStore.claudeKey() ?? "")
                for b in summarized { if let i = pre.firstIndex(where: { $0.id == b.id }) { pre[i] = b } }
                try InventoryFile.write(pre,to: dir.appendingPathComponent("blocks.json"))
            }
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func buildCatalog() async {
        guard !processing else { return }; await summarize(); guard error == nil else { return }
        processing = true; defer { processing = false; reload() }
        do {
            let all = InventoryFile.allBlocks(root: root).filter(\.summarized)
            guard !all.isEmpty else { message = "Noch keine Arbeitsblöcke vorhanden."; return }
            var existing = catalog; existing.hourlyRate = hourlyRate()
            let days = Array(Set(all.map { InventoryFolder.day($0.start) })).sorted()
            catalog = try await InventoryAI.buildCatalog(blocks: all,checkIns: days.flatMap { checkIns(day: $0) },existing: existing,days: days,root: root,budget: tokenBudget,apiKey: GuideStore.claudeKey() ?? "")
            try catalog.save(root: root)
            approved.removeAll() // Changed analysis must be reviewed again before export.
            for day in days {
                var list = all.filter { InventoryFolder.day($0.start) == day }
                for i in list.indices { list[i].processID = catalog.processes.first { $0.occurrences.contains(list[i].id) }?.id }
                try InventoryFile.write(list,to: root.appendingPathComponent(day).appendingPathComponent("blocks.json"))
            }
            message = "\(catalog.processes.count) Prozesse ausgewertet."; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func ask(manual: Bool = false) {
        guard phase == .running,canAsk(),currentPause == nil,!checkIn.visible,(manual || Date() >= nextQuestion) else { return }
        let today = checkIns(); guard today.count < min(15,max(0,questionsPerDay)),!today.contains(where: { $0.answeredBy == "todayOff" }) else { return }
        let todayBlocks: [InventoryBlock] = (try? InventoryFile.read(InventoryFolder.directory(root: root).appendingPathComponent("blocks.json"))) ?? []
        guard let block = todayBlocks.last(where: { b in b.unclear && !today.contains(where: { $0.blockID == b.id }) }) ?? todayBlocks.last else { return }
        postponedQuestion = false
        lastQuestionActivity = capturedSeconds; nextQuestion = Date().addingTimeInterval(1200)
        let question = block.question.isEmpty ? "Woran arbeitest du gerade, und warum?" : block.question
        checkIn.show(question: question,context: "Seit \(block.start.formatted(date: .omitted,time: .shortened)) · \(block.apps.joined(separator: ", "))") { [weak self] answer,kind in
            guard let self else { return }
            do {
                var values = self.checkIns(); let c = InventoryCheckIn(question: question,answer: answer,answeredBy: kind,blockID: block.id); values.append(c)
                try InventoryFile.write(values,to: InventoryFolder.directory(root: self.root).appendingPathComponent("checkins.json"))
                var blocks: [InventoryBlock] = (try? InventoryFile.read(InventoryFolder.directory(root: self.root).appendingPathComponent("blocks.json"))) ?? []
                if let i = blocks.firstIndex(where: { $0.id == block.id }) { blocks[i].checkIn = c.id; blocks[i].summarized = false }
                try InventoryFile.write(blocks,to: InventoryFolder.directory(root: self.root).appendingPathComponent("blocks.json"))
                if kind == "later" { self.postponedQuestion = true; self.nextQuestion = Date().addingTimeInterval(900) }
                self.reload()
            } catch { self.error = error.localizedDescription }
        }
    }
    func excludeCurrent() { if let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { exclusions += (exclusions.isEmpty ? "" : "\n") + bundle } }
    func reject(_ p: InventoryProcess) {
        catalog.rejectedNames.append(p.name); catalog.processes.removeAll { $0.id == p.id }
        do { try catalog.save(root: root) } catch { self.error = error.localizedDescription }
    }
    func delete(_ block: InventoryBlock) async {
        guard !processing else { return }
        do {
            try await recorder.flush()
            let dir = root.appendingPathComponent(selectedDay), samples = (try? InventoryFile.samples(in: dir)) ?? []
            let kept = samples.filter { $0.end <= block.start || $0.start >= block.end }
            for s in samples where !kept.contains(s) { if let snapshot = s.snapshot { try? FileManager.default.removeItem(at: dir.appendingPathComponent(snapshot)) } }
            let e = Guide.encoder; e.outputFormatting = [.sortedKeys]
            let data = try kept.reduce(into: Data()) { data,s in data.append(try e.encode(s)); data.append(10) }
            try data.write(to: dir.appendingPathComponent("samples.jsonl"),options: .atomic)
            blocks.removeAll { $0.id == block.id }; try InventoryFile.write(blocks,to: dir.appendingPathComponent("blocks.json"))
            try InventoryFile.write(checkIns(day: selectedDay).filter { $0.blockID != block.id },to: dir.appendingPathComponent("checkins.json"))
            for i in catalog.processes.indices where catalog.processes[i].occurrences.contains(block.id) { try? FileManager.default.removeItem(at: InventoryFolder.process(catalog.processes[i].id,root: root)); catalog.processes[i].occurrences.removeAll { $0 == block.id } }
            catalog.metrics(blocks: InventoryFile.allBlocks(root: root),days: catalog.days); try catalog.save(root: root); reload()
        } catch { self.error = error.localizedDescription }
    }
    func handover(_ p: InventoryProcess) async {
        guard !processing else { return }; processing = true; defer { processing = false; reload() }
        do {
            let guides = GuidesFolder.all().filter { url in (try? Guide.load(from: url)).map { $0.title.localizedCaseInsensitiveContains(p.name) || !Set($0.apps).isDisjoint(with: p.apps) } ?? false }.map(\.path)
            _ = try await InventoryAI.writeHandover(process: p,blocks: InventoryFile.allBlocks(root: root),checkIns: InventoryFolder.days(in: root).flatMap { checkIns(day: $0) },guides: guides,root: root,budget: tokenBudget,apiKey: GuideStore.claudeKey() ?? "")
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(InventoryAI.handoverPrompt(p,root: root),forType: .string); message = "Übergabe-Paket erstellt und Auftrag kopiert."
        } catch { self.error = error.localizedDescription }
    }
    func cleanup() {
        let day = InventoryFolder.day(); guard lastCleanup != day else { return }; lastCleanup = day
        for path in InventoryRetention.plan(root: root,imageDays: imageDays,sampleDays: sampleDays) { do { try FileManager.default.removeItem(at: path) } catch { self.error = error.localizedDescription } }
    }
    func deleteImages() { for day in InventoryFolder.days(in: root) { try? FileManager.default.removeItem(at: root.appendingPathComponent(day).appendingPathComponent("snapshots")) }; message = "Inventur-Bilder gelöscht." }
    func exportTeam() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "freigegebene-prozesse.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var reviewed = catalog
            for i in reviewed.processes.indices {
                let id = reviewed.processes[i].id
                if let name = exportNames[id] { reviewed.processes[i].name = SensitiveText.masked(name) }
                if let steps = exportSteps[id] { reviewed.processes[i].steps = steps.components(separatedBy: .newlines).filter { !$0.isEmpty }.map(SensitiveText.masked) }
            }
            let export = InventoryTeamExport(catalog: reviewed,approved: approved,edits: exportEdits)
            try InventoryFile.write(export,to: url); try export.markdown().write(to: url.deletingPathExtension().appendingPathExtension("md"),atomically: true,encoding: .utf8)
            message = "\(export.processes.count) freigegebene Prozesse exportiert."
        } catch { self.error = error.localizedDescription }
    }
}
