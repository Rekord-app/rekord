import AppKit
import SwiftUI
import ScreenCaptureKit
import RecorderCore

@MainActor enum InventoryDiagnostics {
    struct Fixture: Decodable {
        struct Context: Decodable {
            var expected: String?
            var minutes: Double
            var appName: String
            var bundleID: String
            var url: String?
            var windowTitle: String
            var text: String
            var paused: String?
        }
        var date: Date, expected: [String: Int], contexts: [Context]
    }
    static func run(arguments: [String]) async {
        if let i = arguments.firstIndex(of: "--processes-handover"),arguments.count > i+1 {
            await handoverCheck(root: URL(fileURLWithPath: arguments[i+1])); return
        }
        if let i = arguments.firstIndex(of: "--inventory-ui"),arguments.count > i+1 {
            await snapshot(root: URL(fileURLWithPath: arguments[i+1])); return
        }
        guard let i = arguments.firstIndex(of: "--inventory-replay") ?? arguments.firstIndex(of: "--inventory-check"),arguments.count > i+1 else { return }
        let root = URL(fileURLWithPath: arguments[i+1]); try? FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        if arguments.contains("--inventory-check") { await live(root: root,arguments: arguments); return }

        let report = root.appendingPathComponent("inventory-replay.txt")
        var lines: [String] = []
        func log(_ text: String) { lines.append(text); try? lines.joined(separator: "\n").write(to: report,atomically: true,encoding: .utf8); print(text) }
        func check(_ condition: Bool,_ text: String) { log("\(condition ? "PASS" : "FAIL") \(text)") }
        let started = Date()
        do {
            let fixturePath = arguments.firstIndex(of: "--fixture").flatMap { arguments.count > $0+1 ? arguments[$0+1] : nil }
                ?? Bundle.main.path(forResource: "inventory-day",ofType: "json")
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/RecorderCoreTests/Fixtures/inventory-day.json").path
            let fixture = try Guide.decoder.decode(Fixture.self,from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
            let inventory = root.appendingPathComponent("Inventur"), recorder = InventoryRecorder(root: inventory)
            var time = fixture.date, truth: [String: [Date]] = [:]
            for c in fixture.contexts {
                if let name = c.expected { truth[name,default: []].append(time) }
                let end = time.addingTimeInterval(c.minutes*60)
                while time < end {
                    let next = min(end,time.addingTimeInterval(5))
                    let s = InventorySample(start: time,end: next,appName: c.appName,bundleID: c.bundleID,windowTitle: c.windowTitle,url: c.url,focusedRole: "Button",focusedLabel: "Entwurf",text: c.text,paused: c.paused)
                    try await recorder.accept(s); time = next
                }
            }
            try await recorder.flush()
            let dir = InventoryFolder.directory(fixture.date,root: inventory), samples = try InventoryFile.samples(in: dir)
            let pre = InventoryBuilder.preBlocks(samples: samples)
            log("START Fixture \(Int(time.timeIntervalSince(fixture.date)/60)) Min., \(samples.count) Proben, \(pre.count) Vorschnitt-Blöcke; AX=\(GuideAccessibility.trusted), gesperrt=\(InventoryRecorder.locked)")
            let watcher = Task { var endpoints = Set<String>(); while !Task.isCancelled { endpoints.formUnion(MeetingDiagnostics.remoteEndpoints()); try? await Task.sleep(nanoseconds: 300_000_000) }; return endpoints }
            defer { watcher.cancel() }
            let key = GuideStore.claudeKey() ?? ""
            var blocks = try await InventoryAI.summarizeBlocks(preBlocks: pre,samples: samples,checkIns: [],existingProcesses: [],root: inventory,apiKey: key)
            // Two voice answers use the same local speech transcriber as the panel, with synthetic say audio.
            var checks: [InventoryCheckIn] = []
            if #available(macOS 26, *) {
                for (index,line) in ["Ich pflege neue Leads und prüfe Dubletten. Das CRM soll vollständig bleiben.","Ich schreibe einen Kundenbericht aus den erledigten Aufgaben. Vor dem Senden prüft ein Mensch den Entwurf."].enumerated() {
                    let file = root.appendingPathComponent("answer-\(index).m4a")
                    _ = try await GuideDiagnostics.synthesizeNarration([line],to: file)
                    let words = try await MeetingTranscriber.words(in: file,locale: Locale(identifier: "de-DE"))
                    let b = blocks[min(index*3,blocks.count-1)]
                    checks.append(InventoryCheckIn(question: "Woran arbeitest du und warum?",answer: words.map(\.text).joined(separator: " "),answeredBy: "voice",blockID: b.id))
                    try FileManager.default.removeItem(at: file)
                }
                check(checks.count == 2 && checks.allSatisfy { !$0.answer.isEmpty },"2 Sprach-Antworten lokal transkribiert")
            } else { log("BLOCKED Sprache benötigt macOS 26") }
            try InventoryFile.write(checks,to: dir.appendingPathComponent("checkins.json"))
            blocks = try await InventoryAI.summarizeBlocks(preBlocks: blocks,samples: samples,checkIns: checks,existingProcesses: [],root: inventory,apiKey: key)
            for i in blocks.indices { blocks[i].checkIn = checks.first { $0.blockID == blocks[i].id }?.id }
            try InventoryFile.write(blocks,to: dir.appendingPathComponent("blocks.json"))
            var catalog = try await InventoryAI.buildCatalog(blocks: blocks,checkIns: checks,existing: ProcessCatalog(),days: [InventoryFolder.day(fixture.date)],root: inventory,apiKey: key)
            catalog.metrics(blocks: blocks,days: [InventoryFolder.day(fixture.date)]); try catalog.save(root: inventory)
            var recognized = 0
            for (name,starts) in truth.sorted(by: { $0.key < $1.key }) {
                let expectedIDs = Set(blocks.filter { starts.contains($0.start) }.map(\.id))
                let matched = catalog.processes.max { Set($0.occurrences).intersection(expectedIDs).count < Set($1.occurrences).intersection(expectedIDs).count }
                let overlap = matched.map { Set($0.occurrences).intersection(expectedIDs).count } ?? 0
                let count = matched?.occurrences.count ?? 0, wanted = fixture.expected[name]!
                let ok = overlap >= max(1,wanted-1) && abs(count-wanted) <= 1
                if ok { recognized += 1 }
                log("\(ok ? "PASS" : "FAIL") \(name): \(count) statt \(wanted), Zuordnung \(overlap), Modellname \(matched?.name ?? "—")")
            }
            check(recognized >= 5,"\(recognized)/6 Prozesse erkannt mit Häufigkeit ±1")
            let workIDs = Set(blocks.filter { b in truth.values.flatMap { $0 }.contains(b.start) }.map(\.id))
            check(catalog.processes.flatMap(\.occurrences).allSatisfy(workIDs.contains),"kein Rauschen, keine ausgeschlossenen Zeiten im Katalog")
            check(catalog.processes.allSatisfy { $0.minutesPerWeek > 0 && $0.minutesPerWeek <= 1800 },"plausible Stunden aus Blockdauern")
            if let best = catalog.processes.first(where: { $0.automatable == "ja" }) {
                _ = try await InventoryAI.writeHandover(process: best,blocks: blocks,checkIns: checks,guides: [],root: inventory,apiKey: key)
                log("PASS Übergabe-Paket: \(best.id) · \(best.name)")
            } else { log("FAIL kein voll automatisierbarer Prozess") }
            watcher.cancel(); let connections = await watcher.value
            log("INFO Verbindungen: \(connections.sorted())")
            // Compare observed IP endpoints against current DNS answers for the sole permitted API host.
            let dns = Process(); dns.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil"); dns.arguments = ["-q","host","-a","name","api.anthropic.com"]
            let pipe = Pipe(); dns.standardOutput = pipe; try dns.run(); let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),as: UTF8.self); dns.waitUntilExit()
            let ips = output.split(separator: "\n").compactMap { line -> String? in guard line.contains("ip_address:") || line.contains("ipv6_address:") else { return nil }; return line.split(separator: " ").last.map(String.init) }
            check(!connections.isEmpty && connections.allSatisfy { endpoint in ips.contains { endpoint == "\($0):443" || endpoint == "[\($0)]:443" } },"beobachtete Verbindungen nur api.anthropic.com:443")
            var leaks: [String] = []
            if let walker = FileManager.default.enumerator(at: inventory,includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let file as URL in walker.allObjects where ["json","jsonl","md"].contains(file.pathExtension) {
                    let text = try String(contentsOf: file,encoding: .utf8)
                    if text.contains("inventur.fixture@example.test") || text.contains("3704 0044") || text.contains("NIEMALS_SPEICHERN") { leaks.append(file.lastPathComponent) }
                }
            }
            check(leaks.isEmpty,"keine Fake-E-Mail/IBAN/Ausschlussdaten in gespeicherten Dateien: \(leaks)")
            let payload = String(decoding: try InventoryAI.summariesRequest(preBlocks: pre,samples: samples,checkIns: checks,existingProcesses: []).body(),as: UTF8.self)
            check(!payload.contains("inventur.fixture@example.test") && !payload.contains("3704 0044") && !payload.contains("snapshot"),"Anfrage nur maskierter Text")
            let usage: ClaudeUsage = try InventoryFile.read(InventoryFolder.directory(root: inventory).appendingPathComponent("usage.json"))
            check(usage.total > 0,"usage.json: \(usage.inputTokens) Input + \(usage.outputTokens) Output = \(usage.total) Tokens, \(usage.requestBytes) Request-Bytes")
            log("INFO Daten \(Storage.size(of: inventory)) Bytes, Replay \(String(format: "%.1f",Date().timeIntervalSince(started))) s")
            log("DONE")
        } catch { log("FAIL \(error.localizedDescription)") }
    }
    static func live(root: URL,arguments: [String]) async {
        let report = root.appendingPathComponent("inventory-check.txt")
        var lines: [String] = []
        func log(_ value: String) { lines.append(value); try? lines.joined(separator: "\n").write(to: report,atomically: true,encoding: .utf8) }
        guard GuideAccessibility.trusted,!InventoryRecorder.locked else {
            log("BLOCKED Bedienungshilfen=\(GuideAccessibility.trusted), gesperrt=\(InventoryRecorder.locked). Kein Fenster erfasst. OS #211: Recht freigeben und kontrollierten Lauf wiederholen."); return
        }
        do {
            let requested = arguments.firstIndex(of: "--minutes").flatMap { arguments.count > $0+1 ? Int(arguments[$0+1]) : nil } ?? 10
            let minutes = min(30,max(3,requested))
            let (app,_) = try await GuideDiagnostics.prepare(scenario: "web",root: root)
            let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.owningApplication?.processID == app.processIdentifier && ($0.title ?? "").contains("Testfirma") }) else { throw RecorderError.message("Fake-Testfenster fehlt") }
            let recorder = InventoryRecorder(root: root.appendingPathComponent("Inventur"))
            let begin = Date(); var count = 0, idle = false, excluded = false
            while Date().timeIntervalSince(begin) < Double(minutes*60) {
                let elapsed = Date().timeIntervalSince(begin)
                let exclusion = elapsed >= 30 && elapsed < 40 ? [app.bundleIdentifier ?? "com.apple.Safari"] : []
                let sample = try await recorder.tick(paused: nil,exclusions: exclusion,fixtureWindow: window.windowID)
                if sample.paused == nil { count += 1 }
                if sample.paused == "idle" { idle = true }
                if sample.paused == "excluded",sample.windowTitle.isEmpty,sample.text.isEmpty { excluded = true }
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            try await recorder.flush()
            log("\(count > 0 ? "PASS" : "FAIL") aktive Fixture-Proben: \(count)")
            log("\(idle ? "PASS" : "FAIL") Leerlauf-Pause nach 120 Sekunden")
            log("\(excluded ? "PASS" : "FAIL") Ausschluss ohne Titel/Text")
            log("BLOCKED Private-Fenster-Erkennung in den konkret verwendeten Browsern manuell prüfen; reine Logik ist im Core-Test abgedeckt.")
            log("INFO Dauer \(Date().timeIntervalSince(begin)) s; Speicher \(Storage.size(of: root.appendingPathComponent("Inventur"))) Bytes. CPU per ps auf Dev-PID protokollieren.")
        } catch { log("FAIL \(error.localizedDescription)") }
    }

    static func handoverCheck(root: URL) async {
        do {
            let inventoryRoot = root.appendingPathComponent("Inventur")
            var process = InventoryProcess(id: "p-unified-fixture",name: "Kunden-Update als Entwurf",description: "Wöchentlichen Projektstand sachlich als lokalen Mail-Entwurf zusammenfassen.",trigger: "Freitag nach Projektprüfung",steps: ["Aufgaben lesen","Status zusammenfassen","Entwurf ablegen"],apps: ["Aufgabenliste","Mail"],automatable: "ja",method: "claudeCode",successCriteria: ["Nur belegte Aufgaben, kein Versand"])
            process.timesPerWeek = 5; process.minutesPerWeek = 100
            let guideDir = root.appendingPathComponent("Anleitungen/Testfirma.rekord")
            try FileManager.default.createDirectory(at: guideDir,withIntermediateDirectories: true)
            let texts = ["Lies die abgeschlossenen und offenen Aufgaben der Testfirma aus einer lokalen JSON-Datei.","Fasse sie getrennt als Erledigt, Offen und Nächste Schritte zusammen.","Speichere einen lokalen E-Mail-Entwurf; sende nichts."]
            var guide = Guide(title: process.name,duration: 120,steps: texts.enumerated().map { i,text in GuideStep(action: .click,text: text,element: nil,appName: "Testfirma",bundleID: nil,windowTitle: nil,url: nil,time: Double(i*30),position: Point(0.5,0.5)) })
            guide.steps[0].note = "Wenn die Quelldatei fehlt, stoppe und frage nach."
            try guide.save(to: guideDir)
            var profile = ProcessProfile(); profile.guidePaths = [guideDir.path]
            profile.goal = "Verlässlicher Entwurf ohne erfundene Fakten und ohne Versand."
            profile.exceptions = "Bei fehlender Quelldatei oder widersprüchlichen Aufgaben: kein Entwurf, sondern needs_input."
            profile.success = "Test mit drei erledigten und zwei offenen Aufgaben; alle fünf genau einmal, keine erfundenen Angaben. Fehlende Quelldatei darf keine alte EML zurücklassen."
            profile.roi.minutesPerRun = 20; profile.roi.runsPerWeek = 5; profile.roi.setupCost = 600; profile.roi.monthlyCost = 25
            try ProcessProfiles.save([process.id: profile],root: inventoryRoot)
            var catalog = ProcessCatalog(); catalog.processes = [process]; try catalog.save(root: inventoryRoot)
            let h = try await InventoryAI.writeHandover(process: process,blocks: [],checkIns: [],guides: [guideDir.path],root: inventoryRoot,apiKey: GuideStore.claudeKey() ?? "",profile: profile)
            let usage: ClaudeUsage = try InventoryFile.read(InventoryFolder.directory(root: inventoryRoot).appendingPathComponent("usage.json"))
            let report = "PASS echte Text-API: verknüpfte Anleitung + menschlicher Steckbrief + ROI-Szenario.\nSchritte: \(h.steps.count), Ausnahmen: \(h.exceptions.count), Erfolgskriterien: \(h.successCriteria.count).\nTokens: \(usage.total), Request-Bytes: \(usage.requestBytes).\n\n" + h.markdown()
            try report.write(to: root.appendingPathComponent("processes-handover.txt"),atomically: true,encoding: .utf8)
        } catch { try? "FAIL \(error.localizedDescription)".write(to: root.appendingPathComponent("processes-handover.txt"),atomically: true,encoding: .utf8) }
    }
    static func snapshot(root: URL) async {
        let inventory = InventoryStore(root: root.appendingPathComponent("Inventur"),persistent: false)
        inventory.selectedDay = InventoryFolder.days(in: inventory.root).first ?? InventoryFolder.day(); inventory.reload()
        let guideRoot = root.appendingPathComponent("Anleitungen")
        if GuidesFolder.all(in: guideRoot).isEmpty { _ = try? SnapshotFixtures.makeGuides(in: guideRoot) }
        let editor = EditorStore(captureRoot: root,meetingsRoot: root.appendingPathComponent("Meetings"),guidesRoot: guideRoot)
        editor.guides.inventory = inventory
        inventory.availableGuides = { editor.guides.guides }
        inventory.hourlyRate = { 50 }
        if let process = inventory.catalog.processes.first(where: { $0.name.localizedCaseInsensitiveContains("Rechnung") }),let url = editor.guides.guides.first {
            inventory.linkGuide(url,to: process.id)
            var p = inventory.profile(process.id); p.goal = "Aus geprüften Daten einen vollständigen Entwurf erstellen."
            p.exceptions = "Fehlen Pflichtangaben, Rückfrage statt erfundener Daten."; p.success = "Alle Pflichtfelder korrekt, keine erfundenen Angaben, kein automatischer Versand."
            p.roi.setupCost = 600; p.roi.monthlyCost = 25; p.roi.reviewMinutesPerRun = 2
            inventory.saveProfile(p,id: process.id)
        }
        for tab in 0...3 {
            inventory.hubTab = tab; inventory.selectedProcessID = inventory.catalog.processes.first(where: { $0.name.localizedCaseInsensitiveContains("Rechnung") })?.id ?? inventory.catalog.processes.first?.id
            editor.guides.selected = editor.guides.guides.first
            await render(ProcessesView(inventory: inventory,guides: editor.guides).environmentObject(editor),size: CGSize(width: 1200,height: 900),to: root.appendingPathComponent("processes-\(tab).png"))
        }
        await render(ProcessHelpView(),size: CGSize(width: 720,height: 760),to: root.appendingPathComponent("processes-help.png"))
        if let p = inventory.catalog.processes.first {
            await render(ProcessROICard(inventory: inventory,id: p.id,observedMinutes: 20,observedRuns: 5,hourlyRate: 50,source: "Fixture: zehn beobachtete Durchläufe",initialExpanded: true),size: CGSize(width: 760,height: 700),to: root.appendingPathComponent("processes-roi.png"))
        }
        let empty = InventoryStore(root: root.appendingPathComponent("Empty"),persistent: false)
        let emptyGuides = GuideStore(root: root.appendingPathComponent("EmptyGuides"))
        await render(ProcessesView(inventory: empty,guides: emptyGuides).environmentObject(editor),size: CGSize(width: 1000,height: 780),to: root.appendingPathComponent("processes-empty.png"))
    }
    static func render<V: View>(_ content: V,size: CGSize,to file: URL) async {
        let view = NSHostingView(rootView: content.preferredColorScheme(.dark).frame(width: size.width,height: size.height).background(StudioTheme.background))
        let window = NSWindow(contentRect: CGRect(origin: .zero,size: size),styleMask: [.titled],backing: .buffered,defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 700_000_000)
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds,to: bitmap)
            try? bitmap.representation(using: .png,properties: [:])?.write(to: file)
        }
        window.orderOut(nil)
    }
}
