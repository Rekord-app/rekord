import Foundation
@preconcurrency import AVFoundation
import RecorderCore

final class LoomSink {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let renderer = LoomFrameRenderer()
    private var firstTime: CMTime?
    private var lastTime: CMTime?
    private var lastBuffer: CVPixelBuffer?
    private var failure: Error?
    private var filtered: Point?
    private(set) var dropped = 0
    private let crop: CropRect?
    init(url: URL,crop: CropRect? = nil) throws {
        self.crop = crop
        writer = try AVAssetWriter(outputURL: url,fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:1920,AVVideoHeightKey:1080,AVVideoColorPropertiesKey:videoColorProperties,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:MovieExporter.loomBitRate,AVVideoExpectedSourceFrameRateKey:30,AVVideoMaxKeyFrameIntervalKey:60]])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:1920,kCVPixelBufferHeightKey as String:1080,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        guard writer.canAdd(input) else { throw RecorderError.message("Loom-Encoder nicht verfügbar.") }; writer.add(input)
    }
    func append(screen: CVPixelBuffer,camera: CVPixelBuffer?,pointer: Point?,time: CMTime,start: CMTime) {
        guard failure == nil else { return }
        if let lastTime,(time-lastTime).seconds < 1/31.0 { return }
        if firstTime == nil {
            guard writer.startWriting() else { failure = writer.error; return }
            writer.startSession(atSourceTime: start); firstTime = start
        }
        guard input.isReadyForMoreMediaData,let pool = adaptor.pixelBufferPool else { dropped += 1; return }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&output) == kCVReturnSuccess,let output else { dropped += 1; return }
        if let pointer {
            let dt = lastTime.map { max(0,(time-$0).seconds) } ?? 1
            filtered = filtered?.mixed(with: pointer,by: 1-exp(-dt/0.08)) ?? pointer
        }
        var style = Style(); style.padding = 0; style.cornerRadius = 0; style.shadow = 0; style.crop = crop
        renderer.render(to: output,screen: screen,camera: camera,pointer: pointer == nil ? nil : filtered,style: style)
        let presentation = lastTime == nil ? start : time
        if adaptor.append(output,withPresentationTime: presentation) { lastTime = presentation; lastBuffer = output }
        else { failure = writer.error ?? RecorderError.message("Loom-Frame konnte nicht geschrieben werden.") }
    }
    func finish(at endTime: CMTime) async throws {
        if let failure { writer.cancelWriting(); throw failure }
        guard let lastTime,let lastBuffer else { writer.cancelWriting(); throw RecorderError.message("Keine Loom-Frames empfangen.") }
        let final = endTime-CMTime(value: 1,timescale: 30)
        if final > lastTime {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
            guard input.isReadyForMoreMediaData,adaptor.append(lastBuffer,withPresentationTime: final) else { throw writer.error ?? RecorderError.message("Loom-Aufnahmeende konnte nicht geschrieben werden.") }
        }
        writer.endSession(atSourceTime: max(endTime,lastTime+CMTime(value: 1,timescale: 30))); input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RecorderError.message("Loom-Aufnahme konnte nicht abgeschlossen werden.") }
    }
    func cancel() { writer.cancelWriting() }
}
