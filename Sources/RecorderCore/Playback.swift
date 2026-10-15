import Foundation
@preconcurrency import AVFoundation
import CoreVideo

// Real-time editor playback. The edited timeline (retained cuts in source order) becomes one
// AVComposition with screen, camera and audio tracks; a custom compositor draws every frame with
// the shared FrameRenderer, so the editor shows exactly what the exporter writes while AVPlayer
// keeps picture and sound in sync across cuts.

public struct PlaybackTimeline: @unchecked Sendable {
    public let composition: AVMutableComposition
    public let audioMix: AVMutableAudioMix
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID?

    /// Builds the edited composition. Camera and microphone tracks keep their recorded host-clock offsets.
    public static func make(project: Project,directory: URL) async throws -> PlaybackTimeline {
        try project.validate()
        let composition = AVMutableComposition()
        let screenAsset = AVURLAsset(url: directory.appendingPathComponent("screen.mov"))
        guard let screenSource = try await screenAsset.loadTracks(withMediaType: .video).first,
              let screen = composition.addMutableTrack(withMediaType: .video,preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ExportError.message("Videospur fehlt: screen.mov") }
        try await insertEdited(project: project,source: screenSource,offset: 0,into: screen)
        var cameraID: CMPersistentTrackID?
        if project.hasCamera {
            let cameraAsset = AVURLAsset(url: directory.appendingPathComponent("camera.mov"))
            if let cameraSource = try await cameraAsset.loadTracks(withMediaType: .video).first,
               let camera = composition.addMutableTrack(withMediaType: .video,preferredTrackID: kCMPersistentTrackID_Invalid) {
                if try await insertEdited(project: project,source: cameraSource,offset: project.cameraOffset,into: camera) { cameraID = camera.trackID }
                else { composition.removeTrack(camera) }
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = try await appendEditedAudio(project: project,directory: directory,to: composition)
        return PlaybackTimeline(composition: composition,audioMix: mix,screenTrack: screen.trackID,cameraTrack: cameraID)
    }

    /// The video composition depends only on look/zoom/format, so edits that keep the cuts can swap it on a live player item.
    public func videoComposition(project: Project,backgroundImage: CGImage?,height: Int = 1080,fps: Int? = nil) -> AVMutableVideoComposition {
        let (width,height) = project.style.format.dimensions(height: height)
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = RekordVideoCompositor.self
        video.renderSize = CGSize(width: width,height: height)
        video.frameDuration = CMTime(value: 1,timescale: Int32(fps ?? min(60,max(24,project.fps))))
        video.instructions = [RekordCompositionInstruction(timeRange: CMTimeRange(start: .zero,duration: composition.duration),
            renderer: FrameRenderer(project: project,backgroundImage: backgroundImage),screenTrack: screenTrack,cameraTrack: cameraTrack)]
        return video
    }

    /// Inserts the parts of `source` that fall inside retained cuts. `offset` is the source track's start relative to the screen clock.
    @discardableResult
    static func insertEdited(project: Project,source: AVAssetTrack,offset: Double,into track: AVMutableCompositionTrack) async throws -> Bool {
        let available = try await source.load(.timeRange)
        var outputTime = 0.0, inserted = false
        for cut in project.cuts {
            let range = CMTimeRange(start: CMTime(seconds: cut.start-offset,preferredTimescale: 60000),end: CMTime(seconds: cut.end-offset,preferredTimescale: 60000))
            let intersection = CMTimeRangeGetIntersection(range,otherRange: available)
            if intersection.duration.seconds > 0 {
                try track.insertTimeRange(intersection,of: source,at: CMTime(seconds: max(0,outputTime+intersection.start.seconds+offset-cut.start),preferredTimescale: 60000))
                inserted = true
            }
            outputTime += cut.duration
        }
        return inserted
    }
}

/// Adds system sound and narration for the retained cuts, returning their mix levels.
func appendEditedAudio(project: Project,directory: URL,to composition: AVMutableComposition) async throws -> [AVMutableAudioMixInputParameters] {
    var parameters: [AVMutableAudioMixInputParameters] = []
    let sources = [(directory.appendingPathComponent("screen.mov"),0.0)] + (project.hasMicrophone == true ? [(directory.appendingPathComponent("microphone.m4a"),project.microphoneOffset ?? 0)] : [])
    for (url,sourceOffset) in sources {
        // Keep the asset alive: an AVAssetTrack only references its asset weakly.
        let asset = AVURLAsset(url: url)
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first,
              try await audio.load(.timeRange).duration.seconds > 0,
              let track = composition.addMutableTrack(withMediaType: .audio,preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
        guard try await PlaybackTimeline.insertEdited(project: project,source: audio,offset: sourceOffset,into: track) else { composition.removeTrack(track); continue }
        let parameter = AVMutableAudioMixInputParameters(track: track)
        parameter.setVolume(project.audioGain(isMicrophone: url.lastPathComponent == "microphone.m4a"),at: .zero)
        parameters.append(parameter)
    }
    return parameters
}

final class RekordCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let renderer: FrameRenderer
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID?
    init(timeRange: CMTimeRange,renderer: FrameRenderer,screenTrack: CMPersistentTrackID,cameraTrack: CMPersistentTrackID?) {
        self.timeRange = timeRange; self.renderer = renderer; self.screenTrack = screenTrack; self.cameraTrack = cameraTrack
        requiredSourceTrackIDs = ([screenTrack]+(cameraTrack.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

public final class RekordVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    // FrameRenderer keeps no per-frame state, so AVFoundation's look-ahead requests render on several cores.
    private let queue = DispatchQueue(label: "dev.sapunov.rekord.compositor",qos: .userInteractive,attributes: .concurrent)
    private let lock = NSLock()
    private var generation = 0
    public let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock(); let ticket = generation; lock.unlock()
        queue.async { [self] in
            lock.lock(); let cancelled = ticket != generation; lock.unlock()
            if cancelled { request.finishCancelledRequest(); return }
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? RekordCompositionInstruction,
                      let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrack),
                      let screen = instruction.renderer.cgImage(from: screenBuffer),
                      let output = request.renderContext.newPixelBuffer() else {
                    request.finish(with: ExportError.message("Vorschauframe konnte nicht erzeugt werden.")); return
                }
                let camera = instruction.cameraTrack.flatMap { request.sourceFrame(byTrackID: $0) }.flatMap { instruction.renderer.cgImage(from: $0) }
                let project = instruction.renderer.project
                let sourceTime = project.sourceTime(at: request.compositionTime.seconds)
                guard instruction.renderer.render(to: output,screen: screen,camera: camera,time: sourceTime) else {
                    request.finish(with: ExportError.message("Vorschauframe konnte nicht gerendert werden.")); return
                }
                request.finish(withComposedVideoFrame: output)
            }
        }
    }
    public func cancelAllPendingVideoCompositionRequests() {
        lock.lock(); generation += 1; lock.unlock()
    }
}
