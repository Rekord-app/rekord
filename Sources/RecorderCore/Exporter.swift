import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo

public enum ExportError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let s): return s } }
}
public final class VideoFrames {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    public let duration: Double
    private var next: CMSampleBuffer?
    private var current: CMSampleBuffer?
    public init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.message("Videospur fehlt: \(url.lastPathComponent)") }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track,outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.message("Videodecoder nicht verfügbar.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ExportError.message("Video kann nicht gelesen werden.") }
        next = output.copyNextSampleBuffer()
    }
    public func buffer(at time: Double) throws -> CVPixelBuffer? {
        while let sample = next, sample.presentationTimeStamp.seconds <= time+0.00001 {
            current = sample; next = output.copyNextSampleBuffer()
        }
        if reader.status == .failed { throw reader.error ?? ExportError.message("Fehler beim Decodieren.") }
        return current?.imageBuffer
    }
    deinit { reader.cancelReading() }
}
/// Every encoder tags its output as BT.709 (sRGB primaries). Screen capture is requested in
/// sRGB, so pixel values pass through recording, editing and export without a colour shift.
public let videoColorProperties: [String: String] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]

public enum MovieExporter {
    /// Loom links: 6 Mbit/s ceiling. Screen content rarely needs more (measured 15.10.2026: SSIM 0.9972 vs 0.9975 at
    /// 12 Mbit/s on a real recording); the cap only bites during scrolling or video, where it halves the size.
    public static let loomBitRate = 6_000_000
    public static func export(project: Project,directory: URL,to destination: URL,height: Int = 1080,fps: Int = 30,maxBitRate: Int? = nil,progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try project.validate()
        guard [720,1080,2160].contains(height), [30,60].contains(fps) else { throw ExportError.message("Ungültiges Exportformat.") }
        try ExportTarget.validate(destination,projectDirectory: directory)
        let worker = Task.detached(priority: .userInitiated) {
            try await perform(project: project,directory: directory,to: destination,height: height,fps: fps,maxBitRate: maxBitRate,progress: progress)
        }
        try await withTaskCancellationHandler(operation: { try await worker.value },onCancel: { worker.cancel() })
    }
    public static func prepareQuickShare(project: Project,directory: URL,to destination: URL) async throws {
        try project.validate()
        try ExportTarget.validate(destination,projectDirectory: directory)
        let work = destination.deletingLastPathComponent().appendingPathComponent(".focus-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let silent = directory.appendingPathComponent("loom.mov"), final = work.appendingPathComponent("final.mp4")
        try await muxAudio(project: project,directory: directory,silent: silent,destination: final)
        try Task.checkCancellation()
        try ExportTarget.validate(destination,projectDirectory: directory)
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt: final) }
        else { try FileManager.default.moveItem(at: final,to: destination) }
    }
    private static func perform(project: Project,directory: URL,to destination: URL,height: Int,fps: Int,maxBitRate: Int?,progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let work = destination.deletingLastPathComponent().appendingPathComponent(".focus-export-\(UUID().uuidString)")
        try fm.createDirectory(at: work,withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let silent = work.appendingPathComponent("video.mp4"), final = work.appendingPathComponent("final.mp4")
        // Same composition and compositor as editor playback: identical frames, rendered on several cores.
        let timeline = try await PlaybackTimeline.make(project: project,directory: directory)
        let exportHeight = height
        let (width,height) = project.style.format.dimensions(height: exportHeight)
        let reader = try AVAssetReader(asset: timeline.composition)
        let frames = AVAssetReaderVideoCompositionOutput(videoTracks: try await timeline.composition.loadTracks(withMediaType: .video),videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        frames.videoComposition = timeline.videoComposition(project: project,backgroundImage: try BackgroundAsset.load(project: project,directory: directory),height: exportHeight,fps: fps)
        frames.alwaysCopiesSampleData = false
        guard reader.canAdd(frames) else { throw ExportError.message("Videodecoder nicht verfügbar.") }
        reader.add(frames)
        let writer = try AVAssetWriter(outputURL: silent,fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: width,AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: videoColorProperties,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(maxBitRate ?? Int.max,max(8_000_000,width*height*fps/6)),AVVideoExpectedSourceFrameRateKey: fps,AVVideoMaxKeyFrameIntervalKey: fps*2,AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String: width,kCVPixelBufferHeightKey as String: height,kCVPixelBufferCGImageCompatibilityKey as String: true,kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(input) else { throw ExportError.message("MP4-Encoder nicht verfügbar.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError.message("Export konnte nicht gestartet werden.") }
        writer.startSession(atSourceTime: .zero)
        do {
            guard reader.startReading() else { throw reader.error ?? ExportError.message("Video kann nicht gelesen werden.") }
            defer { reader.cancelReading() }
            let expected = Int(ceil(project.editedDuration*Double(fps)))
            var frame = 0
            while frame < expected {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? ExportError.message("Video-Encoder wurde unterbrochen.") }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                let appended = try autoreleasepool { () throws -> Bool in
                    guard let sample = frames.copyNextSampleBuffer() else { return false }
                    guard let buffer = sample.imageBuffer else { return true }
                    guard adaptor.append(buffer,withPresentationTime: CMTime(value: Int64(frame),timescale: Int32(fps))) else { throw writer.error ?? ExportError.message("MP4-Frame konnte nicht geschrieben werden.") }
                    frame += 1
                    return true
                }
                if !appended { break }
                if frame % max(1,fps/4) == 0 { progress(Double(frame)/Double(expected)*0.95) }
            }
            if reader.status == .failed { throw reader.error ?? ExportError.message("Fehler beim Decodieren.") }
            guard frame > 0 else { throw ExportError.message("Keine Videoframes exportiert.") }
            let count = frame
            input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: Int64(count),timescale: Int32(fps)))
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? ExportError.message("MP4 konnte nicht abgeschlossen werden.") }
            try await muxAudio(project: project,directory: directory,silent: silent,destination: final)
            try Task.checkCancellation()
            try ExportTarget.validate(destination,projectDirectory: directory)
            if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination,withItemAt: final) }
            else { try fm.moveItem(at: final,to: destination) }
            progress(1)
        } catch { writer.cancelWriting(); throw error }
    }
    private static func muxAudio(project: Project,directory: URL,silent: URL,destination: URL) async throws {
        let audioComposition = AVMutableComposition()
        let parameters = try await appendEditedAudio(project: project,directory: directory,to: audioComposition)
        guard !parameters.isEmpty else {
            guard let passthrough = AVAssetExportSession(asset: AVURLAsset(url: silent),presetName: AVAssetExportPresetPassthrough) else { throw ExportError.message("MP4-Muxer nicht verfügbar.") }
            passthrough.shouldOptimizeForNetworkUse = true
            try await run(passthrough,to: destination,type: .mp4); return
        }
        let mixed = destination.deletingLastPathComponent().appendingPathComponent("audio.m4a")
        guard let mixer = AVAssetExportSession(asset: audioComposition,presetName: AVAssetExportPresetAppleM4A) else { throw ExportError.message("Audio-Mixer nicht verfügbar.") }
        let mix = AVMutableAudioMix(); mix.inputParameters = parameters; mixer.audioMix = mix
        try await run(mixer,to: mixed,type: .m4a)
        try Task.checkCancellation()
        let videoAsset = AVURLAsset(url: silent), audioAsset = AVURLAsset(url: mixed)
        guard let video = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audio = try await audioAsset.loadTracks(withMediaType: .audio).first else { throw ExportError.message("Export-Spur fehlt.") }
        let composition = AVMutableComposition()
        guard let v = composition.addMutableTrack(withMediaType: .video,preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = composition.addMutableTrack(withMediaType: .audio,preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ExportError.message("Audio-Komposition fehlgeschlagen.") }
        let videoDuration = try await videoAsset.load(.duration)
        try v.insertTimeRange(CMTimeRange(start: .zero,duration: videoDuration),of: video,at: .zero)
        let audioDuration = min(try await audioAsset.load(.duration),videoDuration)
        try a.insertTimeRange(CMTimeRange(start: .zero,duration: audioDuration),of: audio,at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition,presetName: AVAssetExportPresetPassthrough) else { throw ExportError.message("Audio-Muxer nicht verfügbar.") }
        exporter.shouldOptimizeForNetworkUse = true
        try await run(exporter,to: destination,type: .mp4)
    }
    /// Tests only: runs right before an audio export session starts (to cancel exactly at that moment).
    nonisolated(unsafe) public static var testHookBeforeAudioExport: (@Sendable () -> Void)?
    private static func run(_ exporter: AVAssetExportSession,to destination: URL,type: AVFileType) async throws {
        testHookBeforeAudioExport?()
        try Task.checkCancellation()
        // macOS 15+: the async export follows task cancellation itself. Calling cancelExport() as well could hit a
        // session that has not started yet; AVFoundation then throws an Objective-C exception and the app dies
        // (cancel right when the audio phase begins).
        if #available(macOS 15,*) { try await exporter.export(to: destination,as: type); return }
        // Older systems: configure first, so a cancel can only ever reach a fully set-up session.
        exporter.outputURL = destination; exporter.outputFileType = type
        let cancellation = ExportCancellation(exporter)
        try await withTaskCancellationHandler(operation: {
            await exporter.export()
            if exporter.status == .cancelled { throw CancellationError() }
            if exporter.status != .completed { throw exporter.error ?? ExportError.message("Audio-Export fehlgeschlagen.") }
        },onCancel: { cancellation.cancel() })
    }
}

// AVFoundation explicitly permits cancelling a running export from another queue.
private final class ExportCancellation: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}
