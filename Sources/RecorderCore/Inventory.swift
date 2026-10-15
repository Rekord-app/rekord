import Foundation

public struct InventorySample: Codable, Equatable, Sendable {
    public var start: Date, end: Date
    public var appName: String, bundleID: String, windowTitle: String, focusedRole: String, focusedLabel: String, text: String
    public var url: String?, snapshot: String?, paused: String?
    public init(start: Date, end: Date, appName: String = "", bundleID: String = "", windowTitle: String = "", url: String? = nil,
                focusedRole: String = "", focusedLabel: String = "", text: String = "", snapshot: String? = nil, paused: String? = nil) {
        self.start = start; self.end = max(start,end); self.appName = appName; self.bundleID = bundleID; self.windowTitle = windowTitle
        self.url = url; self.focusedRole = focusedRole; self.focusedLabel = focusedLabel; self.text = text; self.snapshot = snapshot; self.paused = paused
        self = sanitized()
    }
    public func sanitized() -> Self {
        var s = self
        if let reason = paused ?? InventoryExclusions.reason(bundleID: bundleID,windowTitle: windowTitle) {
            s.paused = reason; s.appName = ""; s.bundleID = ""; s.windowTitle = ""; s.url = nil; s.focusedRole = ""; s.focusedLabel = ""; s.text = ""; s.snapshot = nil
        } else {
            s.appName = SensitiveText.masked(appName); s.windowTitle = SensitiveText.masked(windowTitle)
            s.url = SensitiveText.strippedURL(url); s.focusedLabel = SensitiveText.masked(focusedLabel)
            s.text = String(SensitiveText.masked(text).prefix(1500))
            if focusedRole.contains("Secure") { s.focusedLabel = ""; s.text = ""; s.snapshot = nil }
            if let path = s.snapshot, !path.hasPrefix("snapshots/" ) || path.contains("..") { s.snapshot = nil }
        }
        return s
    }
    public var seconds: Double { max(0,end.timeIntervalSince(start)) }
    public var host: String { url.flatMap { URL(string: $0)?.host } ?? "" }
    public func sameContext(as other: Self) -> Bool {
        appName == other.appName && bundleID == other.bundleID && windowTitle == other.windowTitle && url == other.url && focusedRole == other.focusedRole && focusedLabel == other.focusedLabel && paused == other.paused
    }
}
public struct InventoryBlock: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var start: Date, end: Date
    public var apps: [String], hosts: [String]
    public var title = "", activity = "", object = "", goal = "", tools: [String] = []
    public var unclear = true, question = ""
    public var checkIn: String?, processID: String?
    public var sampleRange: [Int]
    /// Active seconds excludes bridged interruptions and gaps.
    public var activeSeconds: Double
    public var summarized = false
    public init(start: Date,end: Date,apps: [String],hosts: [String],sampleRange: [Int],activeSeconds: Double) {
        self.id = "b-" + start.ISO8601Format().replacingOccurrences(of: ":",with: "-"); self.start = start; self.end = end
        self.apps = apps; self.hosts = hosts; self.sampleRange = sampleRange; self.activeSeconds = activeSeconds
    }
}
public struct InventoryCheckIn: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var time: Date, question: String, answer: String, answeredBy: String, blockID: String
    public init(time: Date = Date(),question: String,answer: String,answeredBy: String,blockID: String) {
        self.time = time; self.question = SensitiveText.masked(question); self.answer = SensitiveText.masked(answer); self.answeredBy = answeredBy; self.blockID = blockID
    }
}
public struct InventoryProcess: Codable, Equatable, Sendable, Identifiable {
    public var id: String, name: String, description: String, trigger: String
    public var steps: [String], apps: [String], inputs: [String], outputs: [String]
    public var occurrences: [String], minutesPerWeek = 0.0, timesPerWeek = 0.0, euroPerMonth = 0.0
    public var automatable: String, method: String, apiStatus: String, effort: String
    public var openQuestions: [String], successCriteria: [String], examples: [String]
    public init(id: String = "",name: String,description: String = "",trigger: String = "",steps: [String] = [],apps: [String] = [],inputs: [String] = [],outputs: [String] = [],occurrences: [String] = [],automatable: String = "teilweise",method: String = "human",apiStatus: String = "prüfen",effort: String = "M",openQuestions: [String] = [],successCriteria: [String] = [],examples: [String] = []) {
        self.id = id.isEmpty ? "p-" + UUID().uuidString.lowercased() : id; self.name = name; self.description = description; self.trigger = trigger
        self.steps = steps; self.apps = apps; self.inputs = inputs; self.outputs = outputs; self.occurrences = occurrences
        self.automatable = automatable; self.method = method; self.apiStatus = apiStatus; self.effort = effort
        self.openQuestions = openQuestions; self.successCriteria = successCriteria; self.examples = examples
    }
}
public struct ProcessCatalog: Codable, Equatable, Sendable {
    public var schema = "rekord.processes", schemaVersion = 1
    public var updatedAt = Date(), days: [String] = [], hourlyRate: Double = 50, processes: [InventoryProcess] = []
    public var rejectedNames: [String] = []
    public init() {}
    public mutating func metrics(blocks: [InventoryBlock],days: [String]) {
        self.days = Array(Set(days)).sorted(); updatedAt = Date()
        let factor = 5.0 / Double(max(1,self.days.count))
        var assigned = Set<String>()
        for i in processes.indices {
            let ids = Set(processes[i].occurrences)
            let found = blocks.filter { ids.contains($0.id) && assigned.insert($0.id).inserted }
            processes[i].occurrences = found.map(\.id); processes[i].examples = Array(found.prefix(5).map(\.id))
            processes[i].minutesPerWeek = found.reduce(0) { $0 + $1.activeSeconds } / 60 * factor
            processes[i].timesPerWeek = Double(found.count) * factor
            processes[i].euroPerMonth = processes[i].minutesPerWeek / 60 * 52 / 12 * max(0,hourlyRate)
        }
        processes.removeAll { $0.occurrences.isEmpty }
        processes.sort { $0.euroPerMonth > $1.euroPerMonth }
    }
    public static func merge(existing: Self,update: Self) -> Self {
        var result = update; result.rejectedNames = existing.rejectedNames
        var usedIDs = Set<String>()
        for i in result.processes.indices {
            let item = result.processes[i]
            let candidates = existing.processes.filter { !usedIDs.contains($0.id) }
            let match = candidates.first { $0.id == item.id } ?? candidates.first { $0.name.localizedCaseInsensitiveCompare(item.name) == .orderedSame } ?? candidates.max(by: { Set($0.occurrences).intersection(item.occurrences).count < Set($1.occurrences).intersection(item.occurrences).count }).flatMap { Set($0.occurrences).isDisjoint(with: item.occurrences) ? nil : $0 }
            if let match { result.processes[i].id = match.id }
            if usedIDs.contains(result.processes[i].id) { result.processes[i].id = "p-" + UUID().uuidString.lowercased() }
            usedIDs.insert(result.processes[i].id)
        }
        // A complete re-clustering may split a process. Keep IDs unique and never put one
        // observed block back into two processes by re-adding the previous assignment.
        let assigned = Set(result.processes.flatMap(\.occurrences))
        for var old in existing.processes where !usedIDs.contains(old.id) {
            old.occurrences.removeAll { assigned.contains($0) }
            if !old.occurrences.isEmpty { result.processes.append(old) }
        }
        result.processes.removeAll { p in result.rejectedNames.contains { $0.localizedCaseInsensitiveCompare(p.name) == .orderedSame } }
        return result
    }
    public static func load(root: URL = InventoryFolder.url) throws -> Self {
        let catalog: Self = try InventoryFile.read(root.appendingPathComponent("prozesse.json"))
        guard catalog.schema == "rekord.processes", catalog.schemaVersion == 1 else { throw SummaryError.invalid("Unbekanntes Prozess-Schema") }
        return catalog
    }
    public func save(root: URL) throws {
        try InventoryFile.write(self,to: root.appendingPathComponent("prozesse.json"))
        try markdown().write(to: root.appendingPathComponent("prozesse.md"),atomically: true,encoding: .utf8)
    }
    public func markdown() -> String {
        var lines = ["# Arbeits-Inventur", "", "Hochrechnung aus \(days.count) Arbeitstagen, \(Int(hourlyRate)) €/Std. Arbeitswert, keine garantierte Ersparnis.", "", "| Prozess | Mal/Woche | Std./Woche | €/Monat | Automatisierbar |", "|---|---:|---:|---:|---|"]
        for p in processes.sorted(by: { $0.euroPerMonth > $1.euroPerMonth }) {
            lines.append("| \(p.name.replacingOccurrences(of: "|",with: "/")) | \(String(format: "%.1f",p.timesPerWeek)) | \(String(format: "%.1f",p.minutesPerWeek/60)) | \(Int(p.euroPerMonth)) | \(p.automatable) |")
        }
        for p in processes { lines += ["", "## \(p.name)", "", p.description, "", "Auslöser: \(p.trigger)", "", "\(AutomationBrief.methodLabel(p.method)) · API: \(p.apiStatus) · Aufwand: \(p.effort)", ""] + p.steps.enumerated().map { "\($0.offset+1). \($0.element)" } + ["", "Offene Fragen: \(p.openQuestions.joined(separator: "; "))"] }
        return lines.joined(separator: "\n")
    }
}
public enum InventoryBuilder {
    public static func merged(samples: [InventorySample]) -> [InventorySample] {
        var output: [InventorySample] = []
        for raw in samples.sorted(by: { $0.start < $1.start }) {
            let s = raw.sanitized()
            if let last = output.last, last.sameContext(as: s), s.start.timeIntervalSince(last.end) <= 5, s.start >= last.start, s.end.timeIntervalSince(last.start) <= 60, s.snapshot == nil, s.text.isEmpty || s.text == last.text {
                output[output.count-1].end = max(last.end,s.end)
            } else { output.append(s) }
        }
        return output
    }
    public static func preBlocks(samples: [InventorySample]) -> [InventoryBlock] {
        var blocks: [InventoryBlock] = [], current: InventoryBlock?
        func finish() { if let block = current, block.activeSeconds >= 60 { blocks.append(block) }; current = nil }
        for (index,raw) in samples.enumerated() {
            let s = raw.sanitized()
            guard s.paused == nil else { finish(); continue }
            if var block = current {
                let gap = s.start.timeIntervalSince(block.end)
                let same = s.host.isEmpty ? block.apps.contains(s.appName) : block.hosts.contains(s.host)
                if gap >= 0, gap < 30, same {
                    block.end = max(block.end,s.end); block.activeSeconds += s.seconds; block.sampleRange.append(index)
                    block.apps = Array(Set(block.apps + [s.appName])).sorted(); block.hosts = Array(Set(block.hosts + [s.host])).filter { !$0.isEmpty }.sorted(); current = block; continue
                }
                // A short unrelated interruption is omitted from active duration, but never bridge a pause.
                if gap >= 0, gap < 30, s.seconds < 30, index+1 < samples.count {
                    let next = samples[index+1].sanitized()
                    if next.paused == nil, next.start.timeIntervalSince(block.end) < 30,
                       (next.host.isEmpty ? block.apps.contains(next.appName) : block.hosts.contains(next.host)) { continue }
                }
                finish()
            }
            current = InventoryBlock(start: s.start,end: s.end,apps: [s.appName],hosts: s.host.isEmpty ? [] : [s.host],sampleRange: [index],activeSeconds: s.seconds)
        }
        finish(); return blocks
    }
}
public enum InventoryExclusions {
    public static let defaults = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "org.whispersystems.signal-desktop", "dev.sapunov.FocusRecorder", "com.moneymoney-app.retail", "com.buhl-data.Banking4"]
    public static func reason(bundleID: String,windowTitle: String,subrole: String = "",additional: [String] = []) -> String? {
        let bundle = bundleID.lowercased()
        if (defaults+additional).contains(where: { $0.lowercased() == bundle }) || ["1password","bitwarden","keychain","banking"].contains(where: bundle.contains) { return "excluded" }
        let title = (windowTitle + " " + subrole).lowercased()
        if ["privat", "inkognito", "incognito", "inprivate", "private browsing"].contains(where: title.contains) { return "private" }
        // Browser banking/password managers also count as exclusions.
        if ["online-banking", "online banking", "1password", "bitwarden"].contains(where: title.contains) { return "excluded" }
        return nil
    }
}
public enum InventoryFolder {
    public static var url: URL { ProcessInfo.processInfo.environment["REKORD_INVENTORY_ROOT"].map { URL(fileURLWithPath: $0) } ?? RecordingsFolder.url.appendingPathComponent("Inventur") }
    public static func day(_ date: Date = Date()) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date) }
    public static func validDay(_ value: String) -> Bool {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return value.count == 10 && f.date(from: value).map { f.string(from: $0) == value } == true
    }
    public static func days(in root: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(validDay).sorted() }
    public static func directory(_ date: Date = Date(),root: URL = url) -> URL { root.appendingPathComponent(day(date)) }
    public static func process(_ id: String,root: URL) -> URL { root.appendingPathComponent("Prozesse").appendingPathComponent(id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }
}
public enum InventoryFile {
    public static func write<T: Encodable>(_ value: T,to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true)
        try Guide.encoder.encode(value).write(to: url,options: .atomic)
    }
    public static func read<T: Decodable>(_ url: URL) throws -> T { try Guide.decoder.decode(T.self,from: Data(contentsOf: url)) }
    public static func append(_ sample: InventorySample,to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("samples.jsonl"), e = Guide.encoder; e.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        var data = try e.encode(sample.sanitized()); data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url); return }
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    public static func samples(in directory: URL) throws -> [InventorySample] {
        let data = try Data(contentsOf: directory.appendingPathComponent("samples.jsonl"))
        // A crash may leave one incomplete trailing record; do not lose earlier records.
        return data.split(separator: 10).compactMap { try? Guide.decoder.decode(InventorySample.self,from: Data($0)).sanitized() }
    }
    public static func allBlocks(root: URL) -> [InventoryBlock] { InventoryFolder.days(in: root).flatMap { (try? read(root.appendingPathComponent($0).appendingPathComponent("blocks.json")) as [InventoryBlock]) ?? [] } }
}
public enum InventoryRetention {
    public static func plan(root: URL,now: Date = Date(),imageDays: Int = 7,sampleDays: Int = 30) -> [URL] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        var result: [URL] = []
        for day in InventoryFolder.days(in: root) {
            guard let date = f.date(from: day) else { continue }
            let age = Calendar.current.dateComponents([.day],from: date,to: now).day ?? 0, dir = root.appendingPathComponent(day)
            if age > max(0,imageDays) { result.append(dir.appendingPathComponent("snapshots")) }
            if age > max(0,sampleDays) { result.append(dir.appendingPathComponent("samples.jsonl")) }
        }
        return result.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    public static func usage(root: URL) -> (images: Int64,samples: Int64) {
        var images: Int64 = 0, samples: Int64 = 0
        for day in InventoryFolder.days(in: root) {
            let dir = root.appendingPathComponent(day); images += Storage.size(of: dir.appendingPathComponent("snapshots"))
            samples += Int64((try? dir.appendingPathComponent("samples.jsonl").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (images,samples)
    }
}
/// Deliberately separate export type: no block IDs, dates, examples, answers, paths or images can leak by encoding a full catalog.
public struct InventoryTeamExport: Codable {
    public struct Item: Codable {
        public var name: String, description: String, steps: [String], apps: [String], automatable: String, method: String
        public var minutesPerWeek: Double, euroPerMonth: Double
    }
    public var schema = "rekord.processes.team", schemaVersion = 1
    public var processes: [Item]
    public init(catalog: ProcessCatalog,approved: Set<String>,edits: [String: String] = [:]) {
        processes = catalog.processes.filter { approved.contains($0.id) }.map { p in
            Item(name: p.name,description: SensitiveText.masked(edits[p.id] ?? p.description),steps: p.steps,apps: p.apps,automatable: p.automatable,method: p.method,minutesPerWeek: p.minutesPerWeek,euroPerMonth: p.euroPerMonth)
        }
    }
    public func markdown() -> String { "# Freigegebene Prozesse\n\n" + processes.map { "## \($0.name)\n\n\($0.description)\n\n" + $0.steps.map { "- \($0)" }.joined(separator: "\n") }.joined(separator: "\n\n") }
}
