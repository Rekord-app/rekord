import Foundation

/// Guide mode ("Anleitung"): a screen recording with narration becomes a step-by-step guide.
/// A guide is a plain folder below `~/Movies/Rekord/Anleitungen` holding the recording (`project.json`,
/// `screen.mov`, `microphone.m4a`, so it also opens as a video project), the raw click capture `steps.json`,
/// the transcript `transcript.json`, the editable guide `guide.json`, the rendered `guide.md` and `images/`.
/// `guide.json` is the contract for AI agents: fields are only ever added, never renamed.

// MARK: - Raw capture (steps.json)

/// The UI element under a click, read through the Accessibility API at the moment of the click.
public struct GuideElement: Codable, Equatable, Sendable {
    /// AX role without the `AX` prefix, e.g. `Button`, `TextField`, `Link`, `MenuItem`.
    public var role: String
    public var subrole: String?
    /// Localized role description from the app, e.g. „Taste“, „Link“.
    public var roleDescription: String?
    public var title: String?
    public var description: String?
    /// Current value for non-editable elements (pop-up selection, cell text). Never read from text fields.
    public var value: String?
    public var placeholder: String?
    public var help: String?
    /// Text of a label attached to the element (`AXTitleUIElement`) or of its first text child.
    public var labelText: String?
    /// Element frame, normalized to the recorded frame (origin top-left); nil when unknown.
    public var frame: GuideRect?
    /// Password field: never read, always redacted.
    public var secure: Bool
    public init(role: String,subrole: String? = nil,roleDescription: String? = nil,title: String? = nil,description: String? = nil,value: String? = nil,
                placeholder: String? = nil,help: String? = nil,labelText: String? = nil,frame: GuideRect? = nil,secure: Bool = false) {
        self.role = role; self.subrole = subrole; self.roleDescription = roleDescription; self.title = title; self.description = description
        self.value = value; self.placeholder = placeholder; self.help = help; self.labelText = labelText; self.frame = frame; self.secure = secure
    }

    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.replacingOccurrences(of: #"\s+"#,with: " ",options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(120))
    }
    /// The name a person reads on screen. Order: visible title, attached label, accessibility description,
    /// placeholder, value of non-editable controls, tooltip.
    public var label: String? {
        for candidate in [title,labelText,description,placeholder,editable ? nil : value,help] {
            if let text = Self.clean(candidate), !GuideElement.meaningless.contains(text.lowercased()) { return text }
        }
        return nil
    }
    static let meaningless: Set<String> = ["", "button", "taste", "group", "gruppe", "image", "bild", "text", "link", "zelle", "cell"]
    public static let editableRoles: Set<String> = ["TextField","TextArea","ComboBox","SearchField","SecureTextField"]
    public static let actionableRoles: Set<String> = Set(["Button","Link","MenuItem","MenuBarItem","MenuButton","PopUpButton","CheckBox","RadioButton","Tab","DisclosureTriangle",
                                                       "Cell","Row","Incrementor","Slider","Switch","Toolbar","ColorWell","DockItem","Image","StaticText","Heading","ListItem","TabGroup","Outline"]).union(editableRoles)
    /// Containers a click usually only focuses (scroll areas, web page background, window chrome).
    public static let containerRoles: Set<String> = ["Window","ScrollArea","WebArea","Group","SplitGroup","SplitGroupSplitter","Splitter","Unknown","Layout","LayoutArea","Application","List","Table","ScrollBar","Matte","Generic"]
    public var editable: Bool { GuideElement.editableRoles.contains(role) || subrole == "SecureTextField" || secure }
}

/// Normalized rectangle (0…1, origin top-left) in the recorded frame.
public struct GuideRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double,y: Double,width: Double,height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
    public func padded(_ amount: Double) -> GuideRect {
        let px = width*amount, py = height*amount
        return GuideRect(x: x-px,y: y-py,width: width+2*px,height: height+2*py).clipped()
    }
    public func clipped() -> GuideRect {
        let x0 = min(1,max(0,x)), y0 = min(1,max(0,y)), x1 = min(1,max(0,x+width)), y1 = min(1,max(0,y+height))
        return GuideRect(x: x0,y: y0,width: max(0,x1-x0),height: max(0,y1-y0))
    }
    public func contains(_ p: Point) -> Bool { p.x >= x && p.x <= x+width && p.y >= y && p.y <= y+height }
    public func intersects(_ other: GuideRect) -> Bool { x < other.x+other.width && other.x < x+width && y < other.y+other.height && other.y < y+height }
}

public enum GuideEventKind: String, Codable, Sendable { case click, rightClick, typed }

/// One captured interaction (raw, before steps are formed).
public struct GuideEvent: Codable, Equatable, Sendable {
    /// Seconds on the recording's timeline (source time of `screen.mov`).
    public var time: Double
    public var kind: GuideEventKind
    /// Click position, normalized to the recorded frame (origin top-left).
    public var position: Point
    public var element: GuideElement?
    public var appName: String?
    public var bundleID: String?
    public var windowTitle: String?
    /// Page URL for browsers (query and fragment removed at capture).
    public var url: String?
    /// For `typed`: the field's text changed while it had focus. The text itself is never stored.
    public var characters: Int?
    public init(time: Double,kind: GuideEventKind,position: Point,element: GuideElement? = nil,appName: String? = nil,bundleID: String? = nil,
                windowTitle: String? = nil,url: String? = nil,characters: Int? = nil) {
        self.time = time; self.kind = kind; self.position = position; self.element = element; self.appName = appName; self.bundleID = bundleID
        self.windowTitle = windowTitle; self.url = url; self.characters = characters
    }
}

public struct GuideCapture: Codable, Equatable, Sendable {
    public var version = 1
    public var events: [GuideEvent]
    /// Whether the Accessibility permission was granted while recording (without it, element names are missing).
    public var accessibility: Bool
    public init(events: [GuideEvent],accessibility: Bool) { self.events = events; self.accessibility = accessibility }
}

// MARK: - Guide (guide.json)

public enum GuideAction: String, Codable, Sendable, CaseIterable { case click, doubleClick, rightClick, type, select }
public enum GuideAddress: String, Codable, Sendable, CaseIterable {
    case du, sie
    public var label: String { self == .du ? "Du" : "Sie" }
}

public struct GuideRedaction: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var rect: GuideRect
    /// `email`, `iban`, `phone`, `card`, `password`, `manual`.
    public var reason: String
    public init(rect: GuideRect,reason: String) { self.rect = rect; self.reason = reason }
}

public struct GuideStep: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var action: GuideAction
    public var text: String
    public var note: String?
    public var warning: String?
    public var element: GuideElement?
    public var appName: String?
    public var bundleID: String?
    public var windowTitle: String?
    public var url: String?
    /// Click time on the recording's timeline (seconds).
    public var time: Double
    /// Click position, normalized (origin top-left).
    public var position: Point
    /// Image path relative to the guide folder, e.g. `images/step-01.jpg`.
    public var image: String?
    public var redactions: [GuideRedaction] = []
    /// Automatic redaction (OCR) already ran for this step; manual changes are kept on regeneration.
    public var autoRedacted: Bool?
    /// Words spoken around this step (local transcript), used for the step text.
    public var speech: String?
    public init(action: GuideAction,text: String,element: GuideElement?,appName: String?,bundleID: String?,windowTitle: String?,url: String?,time: Double,position: Point) {
        self.action = action; self.text = text; self.element = element; self.appName = appName; self.bundleID = bundleID
        self.windowTitle = windowTitle; self.url = url; self.time = time; self.position = position
    }
}

public struct Guide: Codable, Equatable, Sendable {
    public static let schemaName = "rekord.guide"
    public static let currentSchemaVersion = 1
    public var schema = Guide.schemaName
    public var schemaVersion = Guide.currentSchemaVersion
    public var id = UUID().uuidString
    public var title: String
    public var summary: String?
    public var language = "de"
    public var address: GuideAddress = .du
    public var createdAt: Date
    /// Length of the recording in seconds.
    public var duration: Double
    /// Video of the whole flow, relative to the guide folder.
    public var video = "screen.mov"
    /// Who wrote the step texts: `template` or the Claude model id.
    public var textsBy = "template"
    /// How often the flow runs per week (asked once, used for the automation brief).
    public var frequencyPerWeek: Double?
    /// Show „Diesen Ablauf automatisieren lassen“ on the shared page.
    public var showCallToAction = true
    /// Words spoken before the first click (context for the title).
    public var intro: String?
    public var steps: [GuideStep]
    public init(title: String,createdAt: Date = Date(),duration: Double,steps: [GuideStep]) {
        self.title = title; self.createdAt = createdAt; self.duration = duration; self.steps = steps
    }
    /// Apps used in the flow, in order of first appearance.
    public var apps: [String] {
        var seen: [String] = []
        for name in steps.compactMap(\.appName) where !seen.contains(name) { seen.append(name) }
        return seen
    }
}

public enum GuideFile {
    public static let capture = "steps.json", guide = "guide.json", markdown = "guide.md", transcript = "transcript.json", images = "images"
    public static let pdf = "guide.pdf", brief = "automation-brief.json", briefText = "automation-brief.md", share = "share.json"
}

/// Guides live next to the recordings: `~/Movies/Rekord/Anleitungen`.
public enum GuidesFolder {
    public static var url: URL { RecordingsFolder.url.appendingPathComponent("Anleitungen") }
    public static func isGuide(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(GuideFile.guide).path) }
    public static func newDirectory(title: String,date: Date = Date(),in root: URL = url) throws -> URL {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let name = MeetingsFolder.sanitized([formatter.string(from: date),title].filter { !$0.isEmpty }.joined(separator: " "))
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        var candidate = root.appendingPathComponent(name,isDirectory: true); var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) { candidate = root.appendingPathComponent("\(name) \(index)",isDirectory: true); index += 1 }
        try FileManager.default.createDirectory(at: candidate,withIntermediateDirectories: false)
        return candidate
    }
    /// All guides, newest first.
    public static func all(in root: URL = url) -> [URL] {
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).map { root.appendingPathComponent($0,isDirectory: true) }
        return items.filter(isGuide).compactMap { url in (try? Guide.load(from: url)).map { (url,$0.createdAt) } }.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

extension Guide {
    public static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]; e.dateEncodingStrategy = .iso8601; return e }
    public static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    public static func load(from directory: URL) throws -> Guide {
        let guide = try decoder.decode(Guide.self,from: Data(contentsOf: directory.appendingPathComponent(GuideFile.guide)))
        guard guide.schema == schemaName, guide.schemaVersion <= currentSchemaVersion else { throw GuideError.unsupported }
        return guide
    }
    /// Writes `guide.json` and `guide.md`.
    public func save(to directory: URL) throws {
        try Self.encoder.encode(self).write(to: directory.appendingPathComponent(GuideFile.guide),options: .atomic)
        try markdown().write(to: directory.appendingPathComponent(GuideFile.markdown),atomically: true,encoding: .utf8)
    }
}
extension GuideCapture {
    public static func load(from directory: URL) throws -> GuideCapture {
        try Guide.decoder.decode(GuideCapture.self,from: Data(contentsOf: directory.appendingPathComponent(GuideFile.capture)))
    }
    public func save(to directory: URL) throws {
        try Guide.encoder.encode(self).write(to: directory.appendingPathComponent(GuideFile.capture),options: .atomic)
    }
}

public enum GuideError: LocalizedError {
    case unsupported, noSteps
    public var errorDescription: String? {
        switch self {
        case .unsupported: "Diese Anleitung stammt aus einer neueren Rekord-Version."
        case .noSteps: "In der Aufnahme wurde kein Klick erkannt."
        }
    }
}

// MARK: - Forming steps

public enum GuideBuilder {
    /// Two clicks on the same spot within this time are one double click.
    public static let doubleClickInterval = 0.5
    /// Repeated clicks on the same element within this time collapse into one step.
    public static let repeatInterval = 2.0
    public static let doubleClickDistance = 0.005
    /// Containers a click on which never is a step (they cover the whole window; clicking them only focuses).
    static let pageContainers: Set<String> = ["Window","WebArea","ScrollArea","Application","SplitGroup","Matte","Unknown","LayoutArea"]

    /// One step per meaningful click. Rules:
    /// - Two clicks within 0.5 s and 0.5 % of the frame width (≈ 5–8 px) → one double click (close to the system double-click interval).
    /// - Clicks on the same element (same role and label) within 2 s → one step.
    /// - Clicks on page/window containers (web page background, scroll area, window) only focus → dropped,
    ///   also when labeled (a web area carries the page title). Groups, lists and tables only when unlabeled.
    /// - A click into a text field followed by typing → one `type` step.
    /// - Clicks on Rekord itself are dropped.
    public static func steps(from capture: GuideCapture,ownBundleID: String? = "dev.sapunov.FocusRecorder",address: GuideAddress = .du) -> [GuideStep] {
        var steps: [GuideStep] = []
        var lastClick: GuideEvent?
        let events = capture.events.sorted { $0.time < $1.time }
        for event in events {
            if let own = ownBundleID, event.bundleID == own { continue }
            switch event.kind {
            case .typed:
                // Attach to the step that clicked into the field; otherwise a typing step on its own.
                if let i = steps.indices.last, sameElement(steps[i].element,event.element) || steps[i].action == .click && steps[i].element?.editable == true {
                    steps[i].action = .type
                    if steps[i].element == nil { steps[i].element = event.element }
                } else if let element = event.element {
                    var step = GuideStep(action: .type,text: "",element: element,appName: event.appName,bundleID: event.bundleID,windowTitle: event.windowTitle,url: event.url,time: event.time,position: event.position)
                    step.text = templateText(for: step,address: address); steps.append(step)
                }
            case .click,.rightClick:
                defer { lastClick = event }
                if let last = lastClick, let i = steps.indices.last, event.kind == .click, last.kind == .click,
                   event.time-last.time <= doubleClickInterval, distance(event.position,last.position) <= doubleClickDistance {
                    if steps[i].action == .click { steps[i].action = .doubleClick }
                    continue
                }
                if let i = steps.indices.last, event.time-steps[i].time <= repeatInterval, event.kind == .click,
                   steps[i].element?.label != nil, sameElement(steps[i].element,event.element) { continue }
                let action: GuideAction = event.kind == .rightClick ? .rightClick : (event.element?.role == "MenuItem" ? .select : .click)
                var step = GuideStep(action: action,text: "",element: event.element,appName: event.appName,bundleID: event.bundleID,windowTitle: event.windowTitle,url: event.url,time: event.time,position: event.position)
                step.text = templateText(for: step,address: address)
                steps.append(step)
            }
        }
        // Focus-only clicks: unlabeled containers without a following typing step.
        steps.removeAll { step in
            guard step.action == .click || step.action == .doubleClick, let element = step.element else { return false }
            guard !element.editable else { return false }
            return pageContainers.contains(element.role) || (element.label == nil && GuideElement.containerRoles.contains(element.role))
        }
        for i in steps.indices { steps[i].text = templateText(for: steps[i],address: address) }
        return steps
    }
    static func distance(_ a: Point,_ b: Point) -> Double { ((a.x-b.x)*(a.x-b.x)+(a.y-b.y)*(a.y-b.y)).squareRoot() }
    static func sameElement(_ a: GuideElement?,_ b: GuideElement?) -> Bool {
        guard let a, let b else { return false }
        return a.role == b.role && a.label == b.label && (a.frame == nil || b.frame == nil || a.frame == b.frame || a.label != nil)
    }

    /// Fallback text without Claude: verb + element name in quotes.
    public static func templateText(for step: GuideStep,address: GuideAddress) -> String {
        let du = address == .du
        let name = step.element?.label.map { "„\($0)“" }
        let role = step.element.map(roleName) ?? ""
        let target = name.map { role.isEmpty ? $0 : "\(role) \($0)" } ?? (role.isEmpty ? "die markierte Stelle" : "die markierte Stelle (\(role))")
        if step.element?.secure == true { return du ? "Gib dein Passwort ein." : "Geben Sie Ihr Passwort ein." }
        switch step.action {
        case .click: return du ? "Klicke auf \(target)." : "Klicken Sie auf \(target)."
        case .doubleClick: return du ? "Doppelklicke auf \(target)." : "Doppelklicken Sie auf \(target)."
        case .rightClick: return du ? "Klicke mit der rechten Maustaste auf \(target)." : "Klicken Sie mit der rechten Maustaste auf \(target)."
        case .select: return du ? "Wähle \(target)." : "Wählen Sie \(target)."
        case .type:
            let field = name.map { "das Feld \($0)" } ?? "das markierte Feld"
            return du ? "Klicke in \(field) und gib den Wert ein." : "Klicken Sie in \(field) und geben Sie den Wert ein."
        }
    }
    /// German noun for an AX role ("die Schaltfläche" etc. would need articles; we use a neutral prefix).
    public static func roleName(_ element: GuideElement) -> String {
        switch element.role {
        case "Button","MenuButton": "die Schaltfläche"
        case "Link": "den Link"
        case "MenuItem","MenuBarItem": "den Menüpunkt"
        case "PopUpButton","ComboBox": "das Auswahlfeld"
        case "CheckBox","Switch": "das Kästchen"
        case "RadioButton": "die Option"
        case "Tab": "den Tab"
        case "TextField","TextArea","SearchField","SecureTextField": "das Feld"
        case "Cell","Row": "die Zeile"
        case "DockItem": "das Dock-Symbol"
        default: ""
        }
    }

    /// Spoken sentences per step. Whole sentences (split at `.`, `?`, `!` and pauses over 0.8 s) go to the first
    /// click after the sentence's anchor (0.3 s grace), so „Jetzt klicke ich auf Speichern“ and an explanation while
    /// clicking stay with that click. The anchor is the second word's start: Apple's SpeechTranscriber stretches the
    /// first word of a sentence back over the preceding pause. Sentences before the first click that end more than
    /// 1 s before it are the intro; sentences after the last click belong to the last step.
    public static func assignSpeech(_ words: [TranscriptWord],offset: Double,to guide: inout Guide) {
        guard !words.isEmpty else { return }
        var groups: [[TranscriptWord]] = [], current: [TranscriptWord] = []
        for word in words.map({ TranscriptWord(text: $0.text,start: $0.start+offset,end: $0.end+offset) }) {
            if let last = current.last, word.start-last.end > 0.8 { groups.append(current); current = [] }
            current.append(word)
            if word.text.trimmingCharacters(in: .whitespaces).last.map({ ".?!".contains($0) }) ?? false { groups.append(current); current = [] }
        }
        if !current.isEmpty { groups.append(current) }
        func text(_ ws: [TranscriptWord]) -> String {
            ws.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
                .replacingOccurrences(of: #" ([,.?!:;])"#,with: "$1",options: .regularExpression)
        }
        // A lone punctuation token closes the previous sentence.
        groups = groups.reduce(into: []) { result,group in
            if text(group).allSatisfy({ ".?!,;:".contains($0) }), !result.isEmpty { result[result.count-1] += group } else { result.append(group) }
        }
        let times = guide.steps.map(\.time)
        guard let first = times.first else { guide.intro = groups.map(text).joined(separator: " "); return }
        var intro: [String] = [], perStep = Array(repeating: [String](),count: times.count)
        for group in groups {
            let anchor = group.count > 1 ? group[1].start : max(group[0].start,group[0].end-0.4)
            let index = times.firstIndex { anchor < $0+0.3 } ?? times.count-1
            let sentence = text(group)
            if sentence.isEmpty { continue }
            if index == 0, (group.last?.end ?? 0) < first-1 { intro.append(sentence) } else { perStep[index].append(sentence) }
        }
        guide.intro = intro.isEmpty ? nil : intro.joined(separator: " ")
        for i in guide.steps.indices { guide.steps[i].speech = perStep[i].isEmpty ? nil : perStep[i].joined(separator: " ") }
    }
}

// MARK: - Sensitive data

/// Patterns for automatic redaction (screenshots via OCR) and for masking text before it leaves the Mac.
public enum SensitiveText {
    public static let patterns: [(reason: String,regex: String)] = [
        ("email",#"[A-Za-z0-9._%+\-]+\s?@\s?[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
        ("iban",#"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){11,30}\b"#),
        ("card",#"\b(?:\d[ \-]?){13,19}\b"#),
        ("phone",#"(?:\+|\b00)\d[\d \-/()]{7,}\d|\b0\d{2,5}[ \-/]?\d{3,}(?:[ \-]?\d+)*\b"#),
        ("password",#"[•●∙*]{4,}"#),
    ]
    /// Matches in `text` with their reason. Phone numbers need at least 8 digits; card numbers must pass Luhn.
    public static func matches(in text: String) -> [(reason: String,range: Range<String.Index>)] {
        var result: [(String,Range<String.Index>)] = []
        for (reason,pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text,range: NSRange(text.startIndex...,in: text)) {
                guard let range = Range(match.range,in: text) else { continue }
                let digits = text[range].filter(\.isNumber)
                if reason == "phone", digits.count < 8 { continue }
                if reason == "card", !(13...19).contains(digits.count) || !luhn(String(digits)) { continue }
                if result.contains(where: { $0.1.overlaps(range) }) { continue }
                result.append((reason,range))
            }
        }
        return result
    }
    public static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i,c) in digits.reversed().enumerated() {
            guard var d = c.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
    /// Text with every sensitive match replaced by a placeholder such as `[E-Mail]`.
    public static func masked(_ text: String) -> String {
        var result = text
        for match in matches(in: text).sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(match.range,with: "[\(placeholder(match.reason))]")
        }
        return result
    }
    static func placeholder(_ reason: String) -> String {
        switch reason { case "email": "E-Mail"; case "iban": "IBAN"; case "card": "Kartennummer"; case "phone": "Telefon"; default: "geschwärzt" }
    }
    /// URL without query and fragment (they often carry IDs, tokens or e-mail addresses).
    public static func strippedURL(_ value: String?) -> String? {
        guard let value, var parts = URLComponents(string: value), let scheme = parts.scheme, ["http","https","file"].contains(scheme) else { return nil }
        parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        return parts.string.map(masked)
    }
}

// MARK: - Markdown

extension Guide {
    public func markdown() -> String {
        let date = DateFormatter(); date.locale = Locale(identifier: "de_DE"); date.dateStyle = .medium; date.timeStyle = .short
        var lines = ["# \(title)",""]
        var meta = ["\(steps.count) Schritte","Dauer \(timestamp(duration))",date.string(from: createdAt)]
        if !apps.isEmpty { meta.insert(apps.joined(separator: ", "),at: 0) }
        lines += ["_\(meta.joined(separator: " · "))_",""]
        if let summary, !summary.isEmpty { lines += [summary,""] }
        for (i,step) in steps.enumerated() {
            lines.append("## \(i+1). \(step.text)")
            lines.append("")
            if let image = step.image { lines += ["![Schritt \(i+1)](\(image.replacingOccurrences(of: " ",with: "%20")))",""] }
            if let note = step.note, !note.isEmpty { lines += ["> **Tipp:** \(note)",""] }
            if let warning = step.warning, !warning.isEmpty { lines += ["> **Achtung:** \(warning)",""] }
            var where_: [String] = []
            if let app = step.appName { where_.append(app) }
            if let url = step.url { where_.append(url) } else if let window = step.windowTitle, !window.isEmpty { where_.append(window) }
            where_.append("Video \(timestamp(step.time))")
            lines += ["<sub>\(where_.joined(separator: " · "))</sub>",""]
        }
        lines.append("_Erstellt mit Rekord._")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Transcript words (transcript.json)

/// Spoken words of a guide recording with times on the microphone track (local transcription).
public struct GuideWords: Codable, Equatable, Sendable {
    public struct Word: Codable, Equatable, Sendable { public var text: String; public var start: Double; public var end: Double }
    public var engine: String
    public var locale: String
    /// Start of the microphone track on the screen timeline (seconds).
    public var offset: Double
    public var words: [Word]
    public init(engine: String,locale: String,offset: Double,words: [TranscriptWord]) {
        self.engine = engine; self.locale = locale; self.offset = offset
        self.words = words.map { Word(text: $0.text,start: $0.start,end: $0.end) }
    }
    public var transcriptWords: [TranscriptWord] { words.map { TranscriptWord(text: $0.text,start: $0.start,end: $0.end) } }
    public static func load(from directory: URL) throws -> GuideWords {
        try Guide.decoder.decode(GuideWords.self,from: Data(contentsOf: directory.appendingPathComponent(GuideFile.transcript)))
    }
    public func save(to directory: URL) throws {
        try Guide.encoder.encode(self).write(to: directory.appendingPathComponent(GuideFile.transcript),options: .atomic)
    }
}
