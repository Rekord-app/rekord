import Foundation
import RecorderCore

func testInventory() async throws {
    let start = Date(timeIntervalSince1970: 1_792_000_000)
    func s(_ offset: Double,_ seconds: Double,app: String = "Mail",title: String = "Posteingang",paused: String? = nil) -> InventorySample {
        InventorySample(start: start.addingTimeInterval(offset),end: start.addingTimeInterval(offset+seconds),appName: app,bundleID: "test.mail",windowTitle: title,paused: paused)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("inventory-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    var checks = 0
    func check(_ condition: Bool,_ message: String) { precondition(condition,message); checks += 1 }
    check(InventoryBuilder.merged(samples: [s(0,5),s(5,5)]).count == 1,"merge context")
    check(InventoryBuilder.merged(samples: [s(0,55),s(55,10)]).count == 2,"heartbeat")
    check(InventoryBuilder.merged(samples: [s(0,5),s(5,5,title: "Neu")]).count == 2,"changed context")
    let samples = [s(0,60),s(60,10,app: "Finder"),s(70,60),s(130,5,paused: "idle"),s(135,90),s(260,90),s(350,40)]
    let blocks = InventoryBuilder.preBlocks(samples: samples)
    check(blocks.count == 3,"interruptions, pauses, gaps")
    check(blocks[0].activeSeconds == 120,"interruption not counted")
    check(InventoryBuilder.preBlocks(samples: [s(0,59)]).isEmpty,"minimum length")
    for (bundle,title) in [("com.1password.1password",""),("com.bitwarden.desktop",""),("org.whispersystems.signal-desktop",""),("com.apple.Safari","Privates Surfen"),("browser","InPrivate"),("browser","Incognito"),("bank","Online-Banking")] {
        check(InventoryExclusions.reason(bundleID: bundle,windowTitle: title) != nil,"exclusion \(bundle) \(title)")
    }
    let sensitive = InventorySample(start: start,end: start.addingTimeInterval(60),appName: "Mail",windowTitle: "inventur.fixture@example.test",url: "https://user:secret@example.test/a?token=secret#fragment",focusedLabel: "DE89 3704 0044 0532 0130 00",text: "inventur.fixture@example.test",snapshot: "snapshots/test.jpg")
    let encoded = String(decoding: try Guide.encoder.encode(sensitive),as: UTF8.self)
    check(!encoded.contains("fixture@example") && !encoded.contains("3704") && !encoded.contains("secret"),"mask before persistence")
    let privateSample = InventorySample(start: start,end: start.addingTimeInterval(60),appName: "Safari",windowTitle: "Privat",text: "SECRET",snapshot: "snapshots/a.jpg")
    check(privateSample.text.isEmpty && privateSample.windowTitle.isEmpty && privateSample.snapshot == nil,"paused metadata empty")
    let request = try InventoryAI.summariesRequest(preBlocks: InventoryBuilder.preBlocks(samples: [sensitive]),samples: [sensitive],checkIns: [],existingProcesses: [])
    let body = String(decoding: try request.body(),as: UTF8.self)
    check(!body.contains("snapshots") && !body.contains("image") && !body.contains("fixture@example") && !body.contains("3704"),"payload text only")
    var catalog = ProcessCatalog(); catalog.processes = [InventoryProcess(name: "Mails",occurrences: blocks.map(\.id))]
    catalog.metrics(blocks: blocks,days: ["2026-10-14"])
    check(abs(catalog.processes[0].minutesPerWeek - blocks.reduce(0) { $0+$1.activeSeconds } / 60 * 5) < 1e-8,"weekly minutes")
    check(catalog.processes[0].timesPerWeek == 15,"frequency from occurrences")
    check(abs(catalog.processes[0].euroPerMonth - catalog.processes[0].minutesPerWeek/60*52/12*50) < 1e-8,"monthly euro")
    var update = catalog; update.processes[0].name = "Statusberichte"; update.processes[0].id = "new"
    check(ProcessCatalog.merge(existing: catalog,update: update).processes[0].id == catalog.processes[0].id,"renamed stable ID")
    var rejected = catalog; rejected.rejectedNames = ["Mails"]
    check(ProcessCatalog.merge(existing: rejected,update: catalog).processes.isEmpty,"rejected process stays rejected")
    try catalog.save(root: root)
    check(try ProcessCatalog.load(root: root).schema == "rekord.processes","schema")
    let export = InventoryTeamExport(catalog: catalog,approved: [catalog.processes[0].id],edits: [catalog.processes[0].id: "Freigegebener Text"])
    let json = String(decoding: try Guide.encoder.encode(export),as: UTF8.self)
    check(export.processes.count == 1 && json.contains("Freigegebener Text") && !json.contains("occurrences") && !json.contains("sampleRange") && !json.contains("snapshot") && !json.contains("checkIn"),"team whitelist")
    check(InventoryTeamExport(catalog: catalog,approved: []).processes.isEmpty,"no implicit approval")
    let old = root.appendingPathComponent("2026-09-01")
    try InventoryFile.append(sensitive,to: old)
    try FileManager.default.createDirectory(at: old.appendingPathComponent("snapshots"),withIntermediateDirectories: true)
    try InventoryFile.write(blocks,to: old.appendingPathComponent("blocks.json"))
    let now = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!
    let plan = InventoryRetention.plan(root: root,now: now)
    check(Set(plan.map(\.lastPathComponent)) == ["samples.jsonl","snapshots"],"retention preserves blocks")
    check(try InventoryFile.samples(in: old).count == 1,"JSONL roundtrip")
    check(InventoryFolder.validDay("2026-10-15") && !InventoryFolder.validDay("2026-02-30") && !InventoryFolder.validDay("../x"),"date validation")
    check(try AppCommand.parse(URL(string: "rekord://inventory-pause?minutes=60")!).minutes == 60,"pause command")
    for raw in ["0","-1","1.5","abc","99999999999999999999"] {
        do { _ = try AppCommand.parse(URL(string: "rekord://inventory-pause?minutes=\(raw)")!); preconditionFailure("bad minutes") } catch { checks += 1 }
    }
    do { _ = try await InventoryBudget().request(request,root: root,budget: 1,apiKey: "unused"); preconditionFailure("budget bypass") } catch { checks += 1 }
    let response = Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"{\"blocks\":[]}"}]}"#.utf8)
    check(try ClaudeAPI.decode(InventoryAI.Summaries.self,from: response).blocks.isEmpty,"schema decode offline")
    print("PASS: inventory (\(checks) assertions: privacy, merge, blocks, metrics, stable IDs, retention, text-only, budget, schema, team export, commands)")
}

/// Ten minutes at the production cadence, using an in-memory fake screen. No screen capture or network.
func inventoryBenchmark(root: URL) async throws {
    try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
    let image = try syntheticScreen(lines: ["Kunden-Update – Testfirma", "CRM Import abgeschlossen", "Kontakt inventur.fixture@example.test", "IBAN DE89 3704 0044 0532 0130 00"])
    let start = Date(); var ocrCount = 0, samples: [InventorySample] = []
    let pidFile = root.appendingPathComponent("pid.txt"); try String(ProcessInfo.processInfo.processIdentifier).write(to: pidFile,atomically: true,encoding: .utf8)
    for tick in 0..<120 {
        let now = Date(); var sample = InventorySample(start: now,end: now.addingTimeInterval(5),appName: "Fixture",windowTitle: "Testfirma")
        if tick % 6 == 0 {
            let text = try TextRecognition.recognizeText(in: image,fast: true).map(\.text).joined(separator: "\n")
            sample.text = SensitiveText.masked(text)
            let redactions = try GuideImages.sensitiveRegions(in: image)
            if let rendered = GuideImages.render(image,click: nil,redactions: redactions,maxWidth: 1280) {
                let folder = root.appendingPathComponent("snapshots"); try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
                try GuideImages.writeJPEG(rendered,to: folder.appendingPathComponent("\(tick).jpg"),quality: 0.5)
            }
            ocrCount += 1
        }
        samples.append(sample)
        let deadline = start.addingTimeInterval(Double(tick+1)*5), wait = max(0,deadline.timeIntervalSinceNow)
        try await Task.sleep(nanoseconds: UInt64(wait*1e9))
    }
    for sample in InventoryBuilder.merged(samples: samples) { try InventoryFile.append(sample,to: root) }
    let result = "PASS synthetic benchmark: \(String(format: "%.1f",Date().timeIntervalSince(start))) s, 120 ticks, \(ocrCount) OCR + redacted JPEG, \(Storage.size(of: root)) bytes. CPU measured by ps externally; no live capture.\n"
    try result.write(to: root.appendingPathComponent("benchmark.txt"),atomically: true,encoding: .utf8)
    print(result)
}
