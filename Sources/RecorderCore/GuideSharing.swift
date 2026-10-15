import Foundation

/// Publishes reviewed text, current redacted step images and an optional brief. Raw video and audio stay local.
public enum GuideSharing {
    public struct Record: Codable, Sendable { public var guideID: String; public var url: URL; public var videoID: String?; public var sharedAt: Date }

    /// JSON for `POST /api/guides`.
    public static func payload(guide: Guide,directory: URL,brief: AutomationBrief?) throws -> Data {
        let steps: [[String: Any]] = try guide.steps.map { step in
            var item: [String: Any] = ["text": step.text]
            if let note = step.note { item["note"] = note }
            if let warning = step.warning { item["warning"] = warning }
            if let image = step.image {
                let file = directory.appendingPathComponent(image).resolvingSymlinksInPath().standardizedFileURL
                let images = directory.appendingPathComponent(GuideFile.images).resolvingSymlinksInPath().standardizedFileURL
                guard file.path.hasPrefix(images.path+"/"), file.pathExtension.lowercased() == "jpg" else { throw ShareError.message("Ungültiges Schritt-Bild.") }
                let data = try Data(contentsOf: file)
                guard data.starts(with: [0xff,0xd8,0xff]) else { throw ShareError.message("Schritt-Bilder müssen JPEG sein.") }
                item["image"] = data.base64EncodedString()
            }
            return item
        }
        var body: [String: Any] = ["sourceGuideId": guide.id,"title": guide.title,"apps": guide.apps,"steps": steps,"cta": guide.showCallToAction]
        if let summary = guide.summary { body["summary"] = summary }
        if let brief {
            body["brief"] = ["summary": brief.summary,"saving": brief.savingLine,
                             "groups": brief.groups.map { ["title": $0.title,"automatable": $0.automatable,"method": $0.method,"steps": $0.steps] as [String: Any] }]
        }
        return try JSONSerialization.data(withJSONObject: body,options: [.sortedKeys])
    }

    public static func upload(guide: Guide,directory: URL,client: ShareClient,progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SharedGuide {
        try await client.requireGuideLifecycle()
        var current = guide
        // Re-render from the saved redactions before publishing, never upload stale cached images.
        try await GuideImages.generate(&current,in: directory)
        try current.save(to: directory)
        let brief = try? AutomationBrief.load(from: directory)
        let shared = try await client.uploadGuide(payload(guide: current,directory: directory,brief: brief))
        let record = Record(guideID: shared.id,url: shared.url,videoID: nil,sharedAt: Date())
        try Guide.encoder.encode(record).write(to: directory.appendingPathComponent(GuideFile.share),options: .atomic)
        progress(1); return shared
    }
    public static func record(in directory: URL) -> Record? {
        try? Guide.decoder.decode(Record.self,from: Data(contentsOf: directory.appendingPathComponent(GuideFile.share)))
    }
}
