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
    public let sourceGuideId: String?
    public let videoId: String?
    public let id: String
    public let url: URL
    public let title: String
    public let bytes: Int64
    public let createdAt: String
}
/// Connected legacy video links and revisions of the same local guide are revoked together.
public struct ShareRevocation: Sendable {
    public var guideIDs: Set<String>
    public var videoIDs: Set<String>
    public init(guideID: String? = nil,videoID: String? = nil,guides: [SharedGuide]) {
        guideIDs = Set(guideID.map { [$0] } ?? []); videoIDs = Set(videoID.map { [$0] } ?? [])
        var sources = Set<String>(), changed = true
        while changed {
            changed = false
            for guide in guides where guideIDs.contains(guide.id) || guide.videoId.map(videoIDs.contains) == true || guide.sourceGuideId.map(sources.contains) == true {
                if guideIDs.insert(guide.id).inserted { changed = true }
                if let video = guide.videoId,videoIDs.insert(video).inserted { changed = true }
                if let source = guide.sourceGuideId,sources.insert(source).inserted { changed = true }
            }
        }
    }
    public func description(guides: [SharedGuide]) -> String {
        let titles = guides.filter { guideIDs.contains($0.id) }.map(\.title).joined(separator: "\n")
        return "\(guideIDs.count) Anleitungslinks und \(videoIDs.count) Videolinks werden deaktiviert. Alle Revisionen und gemeinsam verknüpften alten Videos gehören dazu. Lokale Dateien bleiben erhalten.\n\n"+titles
    }
}
public struct ShareServiceStatus: Decodable, Sendable {
    public let service: String
    public let version: Int
    public let maxUploadBytes: Int64
    public let availableBytes: Int64
    public let features: [String]
    public var supportsOffers: Bool { features.contains("video-offers-v1") }
    private enum CodingKeys: String, CodingKey { case service, version, maxUploadBytes, availableBytes, features }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        service = try c.decode(String.self,forKey: .service); version = try c.decode(Int.self,forKey: .version)
        maxUploadBytes = try c.decode(Int64.self,forKey: .maxUploadBytes); availableBytes = try c.decode(Int64.self,forKey: .availableBytes)
        features = try c.decodeIfPresent([String].self,forKey: .features) ?? []
    }
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
        try await requireGuideLifecycle()
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
    /// Publishes a guide page (JSON with step texts, JPEG images as base64, optional brief; raw video is never attached).
    public func uploadGuide(_ body: Data) async throws -> SharedGuide {
        try await requireGuideLifecycle()
        var req = authorized(path: "api/guides",method: "POST")
        req.setValue("application/json",forHTTPHeaderField: "Content-Type")
        req.setValue(String(body.count),forHTTPHeaderField: "Content-Length")
        let session = makeSession(), delegate = TransferDelegate()
        defer { session.invalidateAndCancel() }
        let (data,response) = try await session.upload(for: req,from: body,delegate: delegate)
        try check(response: response,data: data)
        let result = try JSONDecoder().decode(SharedGuide.self,from: data)
        try validate(result)
        return result
    }
    public func requireGuideLifecycle() async throws {
        guard try await status().features.contains("guide-lifecycle-v2") == true else {
            throw ShareError.message("Bitte zuerst den Share-Server aktualisieren. Sichere Anleitungsfreigaben benötigen guide-lifecycle-v2.")
        }
    }
    public func guides() async throws -> [SharedGuide] {
        struct Listing: Decodable { let guides: [SharedGuide] }
        let guides = try JSONDecoder().decode(Listing.self,from: await request(path: "api/guides",method: "GET")).guides
        for guide in guides { try validate(guide) }
        return guides
    }
    private func validate(_ guide: SharedGuide) throws {
        guard guide.id.range(of: "^[A-Za-z0-9_-]{32}$",options: .regularExpression) != nil, guide.bytes >= 0,
              guide.url.scheme == baseURL.scheme,guide.url.host == baseURL.host,guide.url.port == baseURL.port,
              guide.url.path == baseURL.path+"/g/\(guide.id)",guide.url.user == nil,guide.url.password == nil,guide.url.query == nil,guide.url.fragment == nil,
              guide.videoId == nil || guide.videoId?.range(of: "^[A-Za-z0-9_-]{32}$",options: .regularExpression) != nil else {
            throw ShareError.message("Der Server hat einen ungültigen Freigabelink geliefert.")
        }
    }
    public func revokeGuide(_ id: String) async throws {
        try await requireGuideLifecycle()
        guard id.range(of: "^[A-Za-z0-9_-]{32}$",options: .regularExpression) != nil else { throw ShareError.message("Ungültige Freigabe.") }
        _ = try await request(path: "api/guides/\(id)",method: "DELETE")
    }
    public func offers(after: String = "") async throws -> OfferListing {
        let result = try JSONDecoder().decode(OfferListing.self,from: await offerRequest(path: "api/offers",after: after))
        for offer in result.offers { try validateOffer(offer) }; return result
    }
    public func createOffer(_ draft: OfferDraft) async throws -> VideoOffer {
        try draft.validate()
        let result = try JSONDecoder().decode(VideoOffer.self,from: await offerRequest(path: "api/offers",method: "POST",body: JSONEncoder().encode(draft)))
        try validateOffer(result); return result
    }
    public func updateOffer(_ id: String,draft: OfferDraft) async throws -> VideoOffer {
        try draft.validate(); try checkOfferID(id)
        let data = try JSONSerialization.data(withJSONObject: ["title":draft.title,"recipientLabel":draft.recipientLabel,"message":draft.message,"bookingURL":draft.bookingURL,"trackingEnabled":draft.trackingEnabled,"notifyOnFirstOpen":draft.notifyOnFirstOpen])
        let result = try JSONDecoder().decode(VideoOffer.self,from: await offerRequest(path: "api/offers/\(id)",method: "PATCH",body: data))
        try validateOffer(result); return result
    }
    public func setOfferExpiry(_ id: String,date: Date?) async throws -> VideoOffer {
        try checkOfferID(id)
        let data = try JSONSerialization.data(withJSONObject: ["expiresAt":date.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()])
        let result = try JSONDecoder().decode(VideoOffer.self,from: await offerRequest(path: "api/offers/\(id)",method: "PATCH",body: data))
        try validateOffer(result); return result
    }
    public func offerAnalytics(_ id: String,after: String = "") async throws -> OfferAnalytics {
        try checkOfferID(id)
        return try JSONDecoder().decode(OfferAnalytics.self,from: await offerRequest(path: "api/offers/\(id)/analytics",after: after))
    }
    public func offerActivity(after: String = "") async throws -> OfferActivityPage {
        try JSONDecoder().decode(OfferActivityPage.self,from: await offerRequest(path: "api/offer-activity",after: after))
    }
    public func revokeOffer(_ id: String) async throws { try checkOfferID(id); _ = try await offerRequest(path: "api/offers/\(id)",method: "DELETE") }
    public func clearOfferAnalytics(_ id: String) async throws { try checkOfferID(id); _ = try await offerRequest(path: "api/offers/\(id)/analytics",method: "DELETE") }
    public func offerPreview(_ id: String) async throws -> URL {
        try checkOfferID(id)
        struct Preview: Decodable { let url: URL }
        let url = try JSONDecoder().decode(Preview.self,from: await offerRequest(path: "api/offers/\(id)/preview",method: "POST")).url
        guard validOfferURL(url,id: id,preview: true) else { throw ShareError.message("Ungültige Vorschau-URL.") }; return url
    }
    private func checkOfferID(_ id: String) throws {
        guard id.range(of: "^[A-Za-z0-9_-]{32}$",options: .regularExpression) != nil else { throw ShareError.message("Ungültiges Angebot.") }
    }
    private func validOfferURL(_ url: URL,id: String,preview: Bool = false) -> Bool {
        guard url.scheme == baseURL.scheme,url.host == baseURL.host,url.port == baseURL.port,url.path == baseURL.path+"/o/\(id)",url.user == nil,url.password == nil,url.fragment == nil else { return false }
        if !preview { return url.query == nil }
        let items = URLComponents(url: url,resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.count == 1 && items[0].name == "preview" && !(items[0].value ?? "").isEmpty
    }
    private func validateOffer(_ offer: VideoOffer) throws {
        try checkOfferID(offer.id); try checkOfferID(offer.videoId)
        guard validOfferURL(offer.url,id: offer.id),offer.durationSeconds.isFinite,offer.durationSeconds > 0 else { throw ShareError.message("Ungültiges Video-Angebot vom Server.") }
    }
    private func offerRequest(path: String,method: String = "GET",body: Data? = nil,after: String = "") async throws -> Data {
        var req = authorized(path: path,method: method)
        if !after.isEmpty { var parts = URLComponents(url: req.url!,resolvingAgainstBaseURL: false)!; parts.queryItems = [URLQueryItem(name: "after",value: after)]; req.url = parts.url }
        if let body { req.httpBody = body; req.setValue("application/json",forHTTPHeaderField: "Content-Type") }
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let (data,response) = try await session.data(for: req,delegate: TransferDelegate()); try check(response: response,data: data); return data
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
