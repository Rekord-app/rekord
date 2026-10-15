import Foundation

/// Meeting mode: an audio-only call recording with separate tracks, a local transcript and an AI summary.
/// A meeting is a plain folder below `~/Movies/Rekord/Meetings` holding `meeting.json`, `microphone.m4a`,
/// optionally `system.m4a` (only with confirmed consent), `transcript.json`/`.md` and `summary.json`/`.md`.
public enum MeetingStatus: String, Codable, Sendable { case recording, transcribing, summarizing, done, failed }
public enum Speaker: String, Codable, Sendable { case me, other }

public struct Meeting: Codable, Equatable, Sendable {
    public var version = 1
    public var id = UUID().uuidString
    public var title: String
    /// Name of the other person and their company, entered before the call (also used as speaker label).
    public var contact: String
    public var company: String
    public var startedAt: Date
    public var duration = 0.0
    /// Kept for older files; recording no longer asks (consent is obtained in the conversation itself).
    public var consent: Bool
    public var consentConfirmedAt: Date?
    public var ownName: String
    /// Meeting app the call ran in when Rekord picked it up automatically (e.g. „Google Meet“, „Zoom“).
    public var app: String?
    public var hasSystemAudio = false
    /// Start of each track relative to the meeting start (seconds), so both share one timeline.
    public var microphoneOffset = 0.0
    public var systemOffset = 0.0
    public var status: MeetingStatus = .recording
    public var error: String?
    public var transcribedWith: String?
    public var summarizedWith: String?
    /// Seconds from Stop until transcript and summary were written.
    public var processingSeconds: Double?
    public init(title: String,contact: String = "",company: String = "",startedAt: Date = Date(),consent: Bool,ownName: String) {
        self.title = title; self.contact = contact; self.company = company; self.startedAt = startedAt
        self.consent = consent; self.consentConfirmedAt = consent ? startedAt : nil; self.ownName = ownName
    }
    public var otherName: String { contact.trimmingCharacters(in: .whitespaces).isEmpty ? "Gesprächspartner" : contact }
    public func label(_ speaker: Speaker) -> String { speaker == .me ? ownName : otherName }
    public var displayTitle: String {
        let parts = [title,contact,company].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.first ?? "Meeting"
    }
}

public enum MeetingFile {
    public static let meta = "meeting.json", microphone = "microphone.m4a", system = "system.m4a"
    public static let transcript = "transcript.json", transcriptText = "transcript.md", summary = "summary.json", summaryText = "summary.md"
}

/// Meetings live next to the recordings: `~/Movies/Rekord/Meetings`.
public enum MeetingsFolder {
    public static var url: URL { RecordingsFolder.url.appendingPathComponent("Meetings") }
    public static func isMeeting(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(MeetingFile.meta).path) }
    /// New, unique folder named after date and title, e.g. `2026-10-15 10-30 Müller GmbH`.
    public static func newDirectory(for meeting: Meeting,in root: URL = url) throws -> URL {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let name = sanitized([formatter.string(from: meeting.startedAt),meeting.displayTitle == "Meeting" ? "" : meeting.displayTitle].filter { !$0.isEmpty }.joined(separator: " "))
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        var candidate = root.appendingPathComponent(name,isDirectory: true); var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) { candidate = root.appendingPathComponent("\(name) \(index)",isDirectory: true); index += 1 }
        try FileManager.default.createDirectory(at: candidate,withIntermediateDirectories: false)
        return candidate
    }
    static func sanitized(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(80))
    }
    /// All meetings, newest first.
    public static func all(in root: URL = url) -> [URL] {
        // Rebuilt from `root` so the URLs compare equal to those from `newDirectory` (always directory URLs).
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).map { root.appendingPathComponent($0,isDirectory: true) }
        return items.filter(isMeeting).compactMap { url in (try? Meeting.load(from: url)).map { (url,$0.startedAt) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }
}

extension Meeting {
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    public static func load(from directory: URL) throws -> Meeting {
        try decoder.decode(Meeting.self,from: Data(contentsOf: directory.appendingPathComponent(MeetingFile.meta)))
    }
    public func save(to directory: URL) throws {
        try Self.encoder.encode(self).write(to: directory.appendingPathComponent(MeetingFile.meta),options: .atomic)
    }
}

// MARK: - Transcript

/// One recognized word with its time in its own track (seconds from the track start).
public struct TranscriptWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String,start: Double,end: Double) { self.text = text; self.start = start; self.end = end }
}
/// One sentence on the shared meeting timeline.
public struct TranscriptSentence: Codable, Equatable, Sendable {
    public var speaker: Speaker
    public var start: Double
    public var end: Double
    public var text: String
    public init(speaker: Speaker,start: Double,end: Double,text: String) { self.speaker = speaker; self.start = start; self.end = end; self.text = text }
}
public struct Transcript: Codable, Equatable, Sendable {
    public var engine: String
    public var locale: String
    public var sentences: [TranscriptSentence]
    /// Own-track sentences dropped as speaker echo of the other side (see `removingEcho`).
    public var echoRemoved: Int?
    public init(engine: String,locale: String,sentences: [TranscriptSentence],echoRemoved: Int? = nil) { self.engine = engine; self.locale = locale; self.sentences = sentences; self.echoRemoved = echoRemoved }

    /// Groups words into sentences: a sentence ends after `.`, `?` or `!`, after a pause of more than
    /// `pause` seconds, or once it grows past `maxWords`. Times are shifted by the track's `offset`.
    public static func sentences(from words: [TranscriptWord],speaker: Speaker,offset: Double,pause: Double = 1.5,maxWords: Int = 60) -> [TranscriptSentence] {
        var result: [TranscriptSentence] = []
        var current: [TranscriptWord] = []
        func flush() {
            guard let first = current.first,let last = current.last else { return }
            let text = current.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
                .replacingOccurrences(of: #" ([,.?!:;])"#,with: "$1",options: .regularExpression)
            if !text.isEmpty { result.append(TranscriptSentence(speaker: speaker,start: first.start+offset,end: last.end+offset,text: text)) }
            current = []
        }
        for word in words {
            if let last = current.last, word.start-last.end > pause { flush() }
            current.append(word)
            let trimmed = word.text.trimmingCharacters(in: .whitespaces)
            if current.count >= maxWords || (trimmed.last.map { ".?!".contains($0) } ?? false) { flush() }
        }
        flush()
        return result
    }
    /// Both tracks on one timeline, ordered by start time (ties: own voice first).
    public static func merged(_ tracks: [[TranscriptSentence]]) -> [TranscriptSentence] {
        tracks.flatMap { $0 }.sorted { $0.start != $1.start ? $0.start < $1.start : ($0.speaker == .me && $1.speaker == .other) }
    }
    /// Without headphones the microphone also hears the other side from the speakers. Such echo sentences
    /// (own track, same time ±`window` s, at least `threshold` of their words also spoken by the other side)
    /// are dropped, so the other person's words are not attributed to the user.
    public static func removingEcho(_ sentences: [TranscriptSentence],window: Double = 1.5,threshold: Double = 0.6) -> [TranscriptSentence] {
        func words(_ text: String) -> [String] { text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 } }
        let others = sentences.filter { $0.speaker == .other }
        guard !others.isEmpty else { return sentences }
        return sentences.filter { sentence in
            guard sentence.speaker == .me else { return true }
            let own = words(sentence.text)
            guard own.count >= 3 else { return true }
            let heard = Set(others.filter { $0.end >= sentence.start-window && $0.start <= sentence.end+window }.flatMap { words($0.text) })
            guard !heard.isEmpty else { return true }
            return Double(own.filter(heard.contains).count)/Double(own.count) < threshold
        }
    }
    /// Consecutive sentences of the same speaker joined into turns (for reading and for the summary prompt).
    public var turns: [TranscriptSentence] {
        var result: [TranscriptSentence] = []
        for sentence in sentences {
            if let last = result.last, last.speaker == sentence.speaker, sentence.start-last.end < 4 {
                result[result.count-1].end = max(last.end,sentence.end); result[result.count-1].text += " "+sentence.text
            } else { result.append(sentence) }
        }
        return result
    }
    public func markdown(for meeting: Meeting) -> String {
        var lines = ["# Transkript: \(meeting.displayTitle)","",meetingHeader(meeting),"",
                     "_Maschinell erstellt (\(engine)). Namen und Zahlen vor Verwendung am Ton prüfen.\((echoRemoved ?? 0) > 0 ? " \(echoRemoved!) Sätze, die das Mikrofon nur aus dem Lautsprecher gehört hat, wurden entfernt." : "")_",""]
        for turn in turns { lines.append("**\(meeting.label(turn.speaker))** [\(timestamp(turn.start))]: \(turn.text)"); lines.append("") }
        if turns.isEmpty { lines.append("_Keine Sprache erkannt._") }
        return lines.joined(separator: "\n")
    }
    /// Plain text for the summary request: a line per speaker change, every sentence with its own `[mm:ss]`
    /// so quotes can be dated precisely.
    public func promptText(for meeting: Meeting) -> String {
        var lines: [String] = []
        var speaker: Speaker?
        for sentence in sentences {
            let piece = "[\(timestamp(sentence.start))] \(sentence.text)"
            if speaker == sentence.speaker, !lines.isEmpty { lines[lines.count-1] += " "+piece }
            else { lines.append("\(meeting.label(sentence.speaker)): \(piece)"); speaker = sentence.speaker }
        }
        return lines.joined(separator: "\n")
    }
    public func save(to directory: URL,meeting: Meeting) throws {
        try Meeting.encoder.encode(self).write(to: directory.appendingPathComponent(MeetingFile.transcript),options: .atomic)
        try markdown(for: meeting).write(to: directory.appendingPathComponent(MeetingFile.transcriptText),atomically: true,encoding: .utf8)
    }
    public static func load(from directory: URL) throws -> Transcript {
        try Meeting.decoder.decode(Transcript.self,from: Data(contentsOf: directory.appendingPathComponent(MeetingFile.transcript)))
    }
}

public func timestamp(_ seconds: Double) -> String {
    let s = Int(max(0,seconds.isFinite ? seconds : 0))
    return s >= 3600 ? String(format: "%d:%02d:%02d",s/3600,s/60%60,s%60) : String(format: "%02d:%02d",s/60,s%60)
}
func meetingHeader(_ meeting: Meeting) -> String {
    let date = DateFormatter(); date.locale = Locale(identifier: "de_DE"); date.dateStyle = .medium; date.timeStyle = .short
    var parts = ["\(date.string(from: meeting.startedAt)) · \(timestamp(meeting.duration))"]
    if !meeting.contact.isEmpty || !meeting.company.isEmpty { parts.append([meeting.contact,meeting.company].filter { !$0.isEmpty }.joined(separator: ", ")) }
    if !meeting.hasSystemAudio { parts.append("nur eigenes Mikrofon") }
    return parts.joined(separator: " · ")
}
