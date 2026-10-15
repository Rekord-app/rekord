import Foundation
import Security

/// Request/response channel from local tools (the MCP server) to the running app: `rekord://call?op=…&id=…`.
/// The arguments travel in a file next to status.json, together with a random key that only local processes
/// can read. A web page can open a rekord:// URL but cannot write that file, so it can never trigger a call.
public enum AppCall {
    public static var folder: URL { SupportFolder.url.appendingPathComponent("calls") }
    static var keyFile: URL { SupportFolder.url.appendingPathComponent("call-key") }
    /// Request id and operation names: short and plain, nothing that could leave the calls folder.
    public static func validID(_ id: String) -> Bool { !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    public static func validOperation(_ op: String) -> Bool { op.range(of: "^[a-z]+\\.[a-z_]+$",options: .regularExpression) != nil && op.count <= 48 }

    /// The shared key; created once (0600) by whoever needs it first.
    public static func key() throws -> String {
        let files = FileManager.default
        func stored() -> String? { (try? Data(contentsOf: keyFile)).flatMap { String(data: $0,encoding: .utf8) }.flatMap { $0.count == 64 ? $0 : nil } }
        if let key = stored() { return key }
        if files.fileExists(atPath: keyFile.path) { try files.removeItem(at: keyFile) }   // damaged: replace
        try files.createDirectory(at: SupportFolder.url,withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0,count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw ProjectError.message("Zufallsschlüssel nicht verfügbar.") }
        // Exclusive create: if another process wins the race, both use its key.
        try? Data(bytes.map { String(format: "%02x",$0) }.joined().utf8).write(to: keyFile,options: .withoutOverwriting)
        try files.setAttributes([.posixPermissions: 0o600],ofItemAtPath: keyFile.path)
        guard let key = stored() else { throw ProjectError.message("Schlüssel für App-Aufrufe konnte nicht gespeichert werden.") }
        return key
    }
    static func request(_ id: String) -> URL { folder.appendingPathComponent("\(id).request.json") }
    static func result(_ id: String) -> URL { folder.appendingPathComponent("\(id).result.json") }
    static func prepareFolder() throws {
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],ofItemAtPath: folder.path)
    }

    /// Caller side: stores the arguments; then open `url(op:id:)`.
    public static func writeRequest(id: String,op: String,arguments: [String: Any]) throws {
        guard validID(id), validOperation(op) else { throw ProjectError.message("Ungültiger Aufruf.") }
        try prepareFolder()
        let body: [String: Any] = ["key": try key(),"op": op,"arguments": arguments,"created": Date().timeIntervalSince1970]
        try JSONSerialization.data(withJSONObject: body).write(to: request(id),options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],ofItemAtPath: request(id).path)
    }
    public static func url(op: String,id: String) -> URL {
        var components = URLComponents(); components.scheme = "rekord"; components.host = "call"
        components.queryItems = [URLQueryItem(name: "op",value: op),URLQueryItem(name: "id",value: id)]
        return components.url!
    }
    /// App side: the arguments of a call, only if the request file carries the key and is fresh. The file is consumed.
    public static func readRequest(id: String,op: String) throws -> [String: Any] {
        guard validID(id), validOperation(op) else { throw ProjectError.message("Ungültiger Aufruf.") }
        let file = request(id)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file), let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProjectError.message("Aufruf ohne Auftragsdatei abgelehnt.")
        }
        guard let given = body["key"] as? String, given == (try key()), body["op"] as? String == op else { throw ProjectError.message("Aufruf mit falschem Schlüssel abgelehnt.") }
        guard let created = body["created"] as? Double, abs(Date().timeIntervalSince1970-created) < 120 else { throw ProjectError.message("Aufruf ist abgelaufen.") }
        return body["arguments"] as? [String: Any] ?? [:]
    }
    /// App side: the outcome for the caller.
    public static func writeResult(id: String,result: [String: Any]?,error: String?) {
        guard validID(id), (try? prepareFolder()) != nil else { return }
        var body: [String: Any] = ["ok": error == nil]
        if let error { body["error"] = error }
        if let result { body["result"] = result }
        guard let data = try? JSONSerialization.data(withJSONObject: body,options: [.withoutEscapingSlashes]) else {
            writeResult(id: id,result: nil,error: error ?? "Ergebnis ließ sich nicht speichern."); return
        }
        try? data.write(to: self.result(id),options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],ofItemAtPath: self.result(id).path)
    }
    /// Caller side: the outcome once it exists (and removes it).
    public static func takeResult(id: String) -> (ok: Bool,result: [String: Any],error: String?)? {
        let file = result(id)
        guard let data = try? Data(contentsOf: file), let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        try? FileManager.default.removeItem(at: file)
        return (body["ok"] as? Bool ?? false,body["result"] as? [String: Any] ?? [:],body["error"] as? String)
    }
}
