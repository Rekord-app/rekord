import Foundation
import AVFoundation

/// Sharing a guide: the screen video with the narration as one MP4 (existing video upload), then the guide
/// page (texts, redacted step images, short brief). Nothing else leaves the Mac. The link is stored in `share.json`.
public enum GuideSharing {
    public struct Record: Codable, Sendable { public var guideID: String; public var url: URL; public var videoID: String?; public var sharedAt: Date }

    /// Screen video plus microphone track (at its offset) as an MP4, without re-encoding.
    public static func videoFile(directory: URL,guide: Guide) async throws -> URL {
        let project = try Project.load(from: directory)
        let composition = AVMutableComposition()
        let screen = AVURLAsset(url: directory.appendingPathComponent(guide.video))
        guard let video = try await screen.loadTracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(withMediaType: .video,preferredTrackID: kCMPersistentTrackID_Invalid) else { throw GuideImageError.write }
        let duration = try await screen.load(.duration)
        try track.insertTimeRange(CMTimeRange(start: .zero,duration: duration),of: video,at: .zero)
        let microphone = directory.appendingPathComponent("microphone.m4a")
        if FileManager.default.fileExists(atPath: microphone.path) {
            let audio = AVURLAsset(url: microphone)
            if let source = try await audio.loadTracks(withMediaType: .audio).first,
               let target = composition.addMutableTrack(withMediaType: .audio,preferredTrackID: kCMPersistentTrackID_Invalid) {
                let length = try await audio.load(.duration), offset = CMTime(seconds: max(0,project.microphoneOffset ?? 0),preferredTimescale: 600)
                let usable = CMTimeMinimum(length,CMTimeSubtract(duration,offset))
                if usable > .zero { try target.insertTimeRange(CMTimeRange(start: .zero,duration: usable),of: source,at: offset) }
            }
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("rekord-guide-\(guide.id).mp4")
        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition,presetName: AVAssetExportPresetPassthrough) else { throw GuideImageError.write }
        try await export.export(to: output,as: .mp4)
        return output
    }

    /// JSON for `POST /api/guides`.
    public static func payload(guide: Guide,directory: URL,videoID: String?,brief: AutomationBrief?) throws -> Data {
        let steps: [[String: Any]] = try guide.steps.map { step in
            var item: [String: Any] = ["text": step.text]
            if let note = step.note { item["note"] = note }
            if let warning = step.warning { item["warning"] = warning }
            if let image = step.image { item["image"] = try Data(contentsOf: directory.appendingPathComponent(image)).base64EncodedString() }
            return item
        }
        var body: [String: Any] = ["title": guide.title,"apps": guide.apps,"steps": steps,"cta": guide.showCallToAction]
        if let summary = guide.summary { body["summary"] = summary }
        if let videoID { body["videoId"] = videoID }
        if let brief {
            body["brief"] = ["summary": brief.summary,"saving": brief.savingLine,
                             "groups": brief.groups.map { ["title": $0.title,"automatable": $0.automatable,"method": $0.method,"steps": $0.steps] as [String: Any] }]
        }
        return try JSONSerialization.data(withJSONObject: body,options: [.sortedKeys])
    }

    public static func upload(guide: Guide,directory: URL,client: ShareClient,progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SharedGuide {
        let file = try await videoFile(directory: directory,guide: guide)
        defer { try? FileManager.default.removeItem(at: file) }
        let video = try await client.upload(file: file,title: guide.title,progress: progress)
        let brief = try? AutomationBrief.load(from: directory)
        let shared = try await client.uploadGuide(payload(guide: guide,directory: directory,videoID: video.id,brief: brief))
        let record = Record(guideID: shared.id,url: shared.url,videoID: video.id,sharedAt: Date())
        try Guide.encoder.encode(record).write(to: directory.appendingPathComponent(GuideFile.share),options: .atomic)
        return shared
    }
    public static func record(in directory: URL) -> Record? {
        try? Guide.decoder.decode(Record.self,from: Data(contentsOf: directory.appendingPathComponent(GuideFile.share)))
    }
}
