import Foundation

/// A `rekord://` command (sent by the MCP server, scripts or any app on the Mac). Parsing never traps:
/// duplicate, unknown or malformed parameters and unknown actions become a readable error.
public struct AppCommand: Equatable, Sendable {
    public enum Action: String, Sendable { case open, start, stop, pause, share, meetings, meeting, meetingStop = "meeting-stop", guides, guide, guideStop = "guide-stop" }
    public enum Source: String, Sendable { case display, area169 = "area-16:9" }
    public var action: Action
    /// Project folder for `open` / `share` (absolute, standardized).
    public var path: URL?
    public var source: Source?
    /// Request id chosen by the caller; the app reports the result for it in status.json.
    public var id: String?

    public struct ParseError: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }
    static let allowed: [Action: Set<String>] = [.open: ["path","id"],.start: ["source","id"],.stop: ["id"],.pause: ["id"],.share: ["path","id"],
                                                 .meetings: ["path","id"],.meeting: ["id"],.meetingStop: ["id"],
                                                 .guides: ["path","id"],.guide: ["id"],.guideStop: ["id"]]

    public static func parse(_ url: URL) throws -> AppCommand {
        func fail(_ message: String) -> ParseError { ParseError(message: message) }
        guard let scheme = url.scheme?.lowercased(), scheme == "rekord" || scheme == "focusrecorder" else { throw fail("Unbekanntes URL-Schema.") }
        guard url.absoluteString.count <= 4096 else { throw fail("Befehl ist zu lang.") }
        guard let components = URLComponents(url: url,resolvingAgainstBaseURL: false) else { throw fail("Befehl ist kein gültiger URL.") }
        let host = (components.host ?? "").lowercased()
        guard let action = Action(rawValue: host == "open-recorder" ? "open" : host) else { throw fail("Unbekannter Befehl: \(host.isEmpty ? "(leer)" : host)") }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard allowed[action]!.contains(item.name) else { throw fail("Unbekannter Parameter für \(action.rawValue): \(item.name)") }
            guard values[item.name] == nil else { throw fail("Parameter doppelt angegeben: \(item.name)") }
            values[item.name] = item.value ?? ""
        }
        var command = AppCommand(action: action)
        if let id = values["id"] {
            guard !id.isEmpty, id.count <= 128, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { throw fail("Ungültige Auftrags-ID.") }
            command.id = id
        }
        if let raw = values["source"] {
            guard let source = Source(rawValue: raw) else { throw fail("source: display oder area-16:9") }
            command.source = source
        }
        if let raw = values["path"] {
            guard !raw.isEmpty, raw.hasPrefix("/"), raw.count <= 1024, !raw.contains("\0") else { throw fail("path muss ein absoluter Pfad sein.") }
            command.path = URL(fileURLWithPath: raw).standardizedFileURL
        }
        // Sharing always names the project explicitly: never fall back to whatever happens to be open.
        if action == .share, command.path == nil { throw fail("share braucht den Pfad der Aufnahme (path).") }
        return command
    }
    public init(action: Action,path: URL? = nil,source: Source? = nil,id: String? = nil) { self.action = action; self.path = path; self.source = source; self.id = id }
}

extension Project {
    /// Loads a project for opening in the editor: the folder must hold a valid project.json and the screen original.
    public static func loadForEditing(from directory: URL) throws -> Project {
        let dir = directory.lastPathComponent == "project.json" ? directory.deletingLastPathComponent() : directory
        guard FileManager.default.fileExists(atPath: dir.path) else { throw ProjectError.message("Aufnahme nicht gefunden: \(dir.path)") }
        let project = try Project.load(from: dir)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("screen.mov").path) else { throw ProjectError.message("Die Bildschirmspur (screen.mov) fehlt in \(dir.lastPathComponent).") }
        return project
    }
}
