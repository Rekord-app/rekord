import Foundation

/// Human assumptions live separately from AI output, so a new analysis never overwrites them.
public struct ProcessProfile: Codable, Equatable, Sendable {
    public var goal = "", trigger = "", inputs = "", outputs = "", exceptions = "", success = ""
    public var guidePaths: [String] = []
    public var reviewed = false
    public var roi = ProcessROIInputs()
    public init() {}
    public var context: String {
        [("Ziel",goal),("Auslöser",trigger),("Eingaben",inputs),("Ergebnis",outputs),("Ausnahmen",exceptions),("Erfolgskriterien",success)]
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }
    public func sanitized() -> Self {
        var p = self
        p.goal = SensitiveText.masked(goal); p.trigger = SensitiveText.masked(trigger); p.inputs = SensitiveText.masked(inputs)
        p.outputs = SensitiveText.masked(outputs); p.exceptions = SensitiveText.masked(exceptions); p.success = SensitiveText.masked(success)
        return p
    }
}
public struct ProcessROIInputs: Codable, Equatable, Sendable {
    public var minutesPerRun: Double?, runsPerWeek: Double?
    /// Explicit scenario, not the model's claim that a step can be automated.
    public var savingFraction = 0.5
    public var reviewMinutesPerRun = 0.0
    public var setupCost: Double?, monthlyCost: Double?
    public init() {}
    public func validate() throws {
        let values = [minutesPerRun,runsPerWeek,setupCost,monthlyCost].compactMap { $0 } + [savingFraction,reviewMinutesPerRun]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }), savingFraction <= 1 else {
            throw SummaryError.invalid("Bitte gültige, nicht negative Zahlen eingeben; der Automatisierungsanteil liegt zwischen 0 und 100 %.")
        }
    }
}
public struct ProcessROI: Codable, Equatable, Sendable {
    public let minutesPerRun: Double, runsPerWeek: Double, hourlyRate: Double
    public let workloadHoursPerMonth: Double, savedHoursPerMonth: Double, capacityValuePerMonth: Double
    public let monthlyNetValue: Double?, paybackMonths: Double?, firstYearROI: Double?
    public let scenarioFraction: Double, remainingMinutesPerRun: Double
    public init?(inputs: ProcessROIInputs,observedMinutes: Double?,observedRuns: Double?,hourlyRate: Double) {
        guard (try? inputs.validate()) != nil,
              let minutes = inputs.minutesPerRun ?? observedMinutes, let runs = inputs.runsPerWeek ?? observedRuns,
              [minutes,runs,hourlyRate].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }) else { return nil }
        minutesPerRun = minutes; runsPerWeek = runs; self.hourlyRate = hourlyRate; scenarioFraction = inputs.savingFraction
        workloadHoursPerMonth = minutes * runs * 52/12/60
        remainingMinutesPerRun = minutes * (1-inputs.savingFraction) + inputs.reviewMinutesPerRun
        savedHoursPerMonth = (minutes-remainingMinutesPerRun) * runs * 52/12/60
        capacityValuePerMonth = savedHoursPerMonth * hourlyRate
        if let cost = inputs.monthlyCost { monthlyNetValue = capacityValuePerMonth-cost } else { monthlyNetValue = nil }
        if let net = monthlyNetValue, let setup = inputs.setupCost {
            paybackMonths = net > 0 ? setup/net : nil
            firstYearROI = setup > 0 ? (net*12-setup)/setup*100 : nil
        } else { paybackMonths = nil; firstYearROI = nil }
    }
}
public enum ProcessProfiles {
    public static func load(root: URL) throws -> [String: ProcessProfile] {
        let url = root.appendingPathComponent("process-profiles.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let profiles: [String: ProcessProfile] = try InventoryFile.read(url)
        for p in profiles.values { try p.roi.validate() }
        return profiles
    }
    public static func save(_ profiles: [String: ProcessProfile],root: URL) throws {
        for p in profiles.values { try p.roi.validate() }
        try InventoryFile.write(profiles.mapValues { $0.sanitized() },to: root.appendingPathComponent("process-profiles.json"))
    }
    /// Resolve only explicit links against the user's current guide library. No matching by app name.
    public static func guides(for profile: ProcessProfile,available: [URL]) -> [URL] {
        let allowed = Set(available.map { $0.standardizedFileURL.path })
        return profile.guidePaths.map { URL(fileURLWithPath: $0).standardizedFileURL }.filter { allowed.contains($0.path) && (try? Guide.load(from: $0)) != nil }
    }
    public static func guideKey(_ guide: Guide) -> String { "guide-" + guide.id }
}
public struct ProcessReadiness: Sendable {
    public let observedRuns: Int, observedDays: Int, guideCount: Int, unclearBlocks: Int
    public let missing: [String]
    public var nextStep: String { missing.first ?? "Übergabe erstellen und den Entwurf mit zehn Testfällen prüfen." }
    public init(process: InventoryProcess,profile: ProcessProfile,blocks: [InventoryBlock],guideCount: Int) {
        let relevant = blocks.filter { process.occurrences.contains($0.id) }
        observedRuns = relevant.count; observedDays = Set(relevant.map { InventoryFolder.day($0.start) }).count
        self.guideCount = guideCount; unclearBlocks = relevant.filter(\.unclear).count
        var gaps: [String] = []
        if !profile.reviewed { gaps.append("Prüfe, ob Name, Schritte und Zuordnung wirklich stimmen.") }
        if profile.goal.isEmpty && process.description.isEmpty { gaps.append("Ergänze das Ziel und woran du ein gutes Ergebnis erkennst.") }
        if guideCount == 0 { gaps.append("Zeige den Ablauf einmal als Anleitung – inklusive Entscheidungen und Ausnahmen.") }
        if profile.exceptions.isEmpty { gaps.append("Beschreibe einen Sonderfall und was dann passieren soll.") }
        if profile.success.isEmpty { gaps.append("Nenne ein prüfbares Erfolgskriterium, etwa Pflichtfelder und erlaubte Fehler.") }
        if process.apiStatus == "prüfen" { gaps.append("Prüfe die Zugänge zu den verwendeten Systemen vor der Umsetzung.") }
        missing = gaps
    }
}
