import Foundation
import CryptoKit

public struct SharedVideo: Codable, Sendable {
    public let id: String
    public let url: URL
    public let title: String
    public let bytes: Int64
    public let sha256: String
    public let createdAt: String
    /// When the link stops working (ISO 8601); nil = never. Older servers don't send it.
    public let expiresAt: String?
    public var expiryDate: Date? { expiresAt.flatMap { ISO8601DateFormatter.withFractions.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } }
}
extension ISO8601DateFormatter {
    static var withFractions: ISO8601DateFormatter { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f }
}
public struct SharedGuide: Codable, Sendable {
    public let id: String
    public let url: URL
    public let title: String
    public let bytes: Int64
    public let createdAt: String
}
public struct ShareServiceStatus: Decodable, Sendable {
    public let service: String
    public let version: Int
    public let maxUploadBytes: Int64
    public let availableBytes: Int64
}
public enum ShareError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let s): return s } }
}
private final class TransferDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void = { _ in }) { self.progress = progress }
    func urlSession(_ session: URLSession,task: URLSessionTask,didSendBodyData bytesSent: Int64,totalBytesSent: Int64,totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { progress(min(1,Double(totalBytesSent)/Double(totalBytesExpectedToSend))) }
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public struct ShareClient: Sendable {
    public let baseURL: URL
    private let token: String
    public init(baseURL: URL,token: String) throws {
        guard let parts = URLComponents(url: baseURL,resolvingAgainstBaseURL: false),parts.user == nil,parts.password == nil,parts.query == nil,parts.fragment == nil,parts.percentEncodedPath.range(of: "^(?:/[A-Za-z0-9_-]+)*/?$",options: .regularExpression) != nil,
              parts.host != nil,parts.scheme == "https" || (parts.scheme == "http" && ["localhost","127.0.0.1","::1","[::1]"].contains(parts.host ?? "")),token.count >= 32 else { throw ShareError.message("Bitte eine HTTPS-Serveradresse und einen gültigen Upload-Schlüssel eingeben. HTTP ist nur für lokale Tests erlaubt.") }
        var normalized = parts
        normalized.path = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { normalized.port = nil }
        self.baseURL = normalized.url!; self.token = token
    }
    public func status() async throws -> ShareServiceStatus {
        let data = try await request(path: "api/status",method: "GET")
        let result = try JSONDecoder().decode(ShareServiceStatus.self,from: data)
        guard result.service == "focus-recorder-share",result.version == 1 else { throw ShareError.message("Der Server unterstützt diese App-Version nicht.") }
        return result
    }
    /// `expiresInDays`: the server deletes the video after that many days (nil = never).
    public func upload(file: URL,title: String,expiresInDays: Int? = nil,progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SharedVideo {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw ShareError.message("Die Aufnahme ist leer.") }
        let hash = try fileHash(file)
        var req = authorized(path: "api/videos",method: "POST")
        req.setValue(hash,forHTTPHeaderField: "X-Focus-SHA256")
        req.setValue("video/mp4",forHTTPHeaderField: "Content-Type")
        req.setValue(String(size),forHTTPHeaderField: "Content-Length")
        let encoded = Data(title.prefix(180).utf8).base64EncodedString().replacingOccurrences(of: "+",with: "-").replacingOccurrences(of: "/",with: "_").replacingOccurrences(of: "=",with: "")
        req.setValue(encoded,forHTTPHeaderField: "X-Focus-Title")
        if let expiresInDays, (1...3650).contains(expiresInDays) { req.setValue(String(expiresInDays),forHTTPHeaderField: "X-Focus-Expires-Days") }
        let delegate = TransferDelegate(progress: progress), session = makeSession()
        defer { session.invalidateAndCancel() }
        let (data,response) = try await session.upload(for: req,fromFile: file,delegate: delegate)
        try check(response: response,data: data)
        let result = try JSONDecoder().decode(SharedVideo.self,from: data)
        try validate(result)
        guard result.bytes == size else { throw ShareError.message("Der Server hat eine falsche Dateigröße bestätigt.") }
        guard result.sha256 == hash else { throw ShareError.message("Die hochgeladene Datei stimmt nicht mit der Aufnahme überein. Bitte erneut versuchen.") }
        progress(1); return result
    }
    public func videos() async throws -> [SharedVideo] {
        struct Listing: Decodable { let videos: [SharedVideo] }
        let videos = try JSONDecoder().decode(Listing.self,from: await request(path: "api/videos",method: "GET")).videos
        for video in videos { try validate(video) }
        return videos
    }
    private func validate(_ video: SharedVideo) throws {
        guard video.id.range(of: "^[A-Za-z0-9_-]{32}$",options: .regularExpression) != nil,video.bytes > 0,
              video.sha256.range(of: "^[a-f0-9]{64}$",options: .regularExpression) != nil,
              video.url.scheme == baseURL.scheme,video.url.host == baseURL.host,video.url.port == baseURL.port,video.url.path == baseURL.path+"/v/\(video.id)",video.url.user == nil,video.url.password == nil,video.url.query == nil,video.url.fragment == nil else { throw ShareError.message("Der Server hat einen ungültigen Freigabelink geliefert.") }
    }
    public func revoke(_ id: String) async throws {
        guard id.range(of: "^[A-Za-z0-9_-]{32}$",options: .regularExpression) != nil else { throw ShareError.message("Ungültige Freigabe.") }
        _ = try await request(path: "api/videos/\(id)",method: "DELETE")
    }
    /// Sets when a link expires; nil keeps it forever.
    public func setExpiry(_ id: String,expiresAt: Date?) async throws -> SharedVideo {
        guard id.range(of: "^[A-Za-z0-9_-]{32}$",options: .regularExpression) != nil else { throw ShareError.message("Ungültige Freigabe.") }
        var req = authorized(path: "api/videos/\(id)",method: "PATCH")
        req.setValue("application/json",forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["expiresAt": expiresAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()])
        let session = makeSession(), delegate = TransferDelegate()
        defer { session.invalidateAndCancel() }
        let (data,response) = try await session.data(for: req,delegate: delegate)
        try check(response: response,data: data)
        let result = try JSONDecoder().decode(SharedVideo.self,from: data)
        try validate(result); return result
    }
    /// Publishes a guide page (JSON with step texts, JPEG images as base64, optional brief and video id).
    public func uploadGuide(_ body: Data) async throws -> SharedGuide {
        var req = authorized(path: "api/guides",method: "POST")
        req.setValue("application/json",forHTTPHeaderField: "Content-Type")
        req.setValue(String(body.count),forHTTPHeaderField: "Content-Length")
        let session = makeSession(), delegate = TransferDelegate()
        defer { session.invalidateAndCancel() }
        let (data,response) = try await session.upload(for: req,from: body,delegate: delegate)
        try check(response: response,data: data)
        let result = try JSONDecoder().decode(SharedGuide.self,from: data)
        guard result.id.range(of: "^[A-Za-z0-9_-]{32}$",options: .regularExpression) != nil,result.url.host == baseURL.host,result.url.scheme == baseURL.scheme,result.url.path == baseURL.path+"/g/\(result.id)" else {
            throw ShareError.message("Der Server hat einen ungültigen Freigabelink geliefert.")
        }
        return result
    }
    public func revokeGuide(_ id: String) async throws {
        guard id.range(of: "^[A-Za-z0-9_-]{32}$",options: .regularExpression) != nil else { throw ShareError.message("Ungültige Freigabe.") }
        _ = try await request(path: "api/guides/\(id)",method: "DELETE")
    }
    private func authorized(path: String,method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path)); request.httpMethod = method
        request.setValue("Bearer \(token)",forHTTPHeaderField: "Authorization"); return request
    }
    private func request(path: String,method: String) async throws -> Data {
        let session = makeSession(), delegate = TransferDelegate()
        defer { session.invalidateAndCancel() }
        let (data,response) = try await session.data(for: authorized(path: path,method: method),delegate: delegate)
        try check(response: response,data: data); return data
    }
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 3600
        config.httpShouldSetCookies = false; config.urlCache = nil
        return URLSession(configuration: config)
    }
    private func check(response: URLResponse,data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw ShareError.message("Keine gültige Serverantwort.") }
        guard (200..<300).contains(response.statusCode) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String:String],let message = object["error"] { throw ShareError.message(message) }
            throw ShareError.message("Freigabe fehlgeschlagen (HTTP \(response.statusCode)).")
        }
    }
}
public func fileHash(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1024*1024),!data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x",$0) }.joined()
}
