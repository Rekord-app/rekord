import Foundation
@preconcurrency import AVFoundation

/// The same audio timing with every sample zeroed. Audio writers treat consecutive buffers as contiguous, so a
/// pause must be filled with silence (not left out) to keep sound in sync with the picture afterwards.
func silenced(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
    guard let format = sample.formatDescription, let source = sample.dataBuffer else { return nil }
    let length = CMBlockBufferGetDataLength(source)
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil,memoryBlock: nil,blockLength: length,blockAllocator: nil,customBlockSource: nil,offsetToData: 0,dataLength: length,flags: kCMBlockBufferAssureMemoryNowFlag,blockBufferOut: &block) == noErr,
          let block, CMBlockBufferFillDataBytes(with: 0,blockBuffer: block,offsetIntoDestination: 0,dataLength: length) == noErr else { return nil }
    var silent: CMSampleBuffer?
    guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil,dataBuffer: block,formatDescription: format,sampleCount: CMSampleBufferGetNumSamples(sample),presentationTimeStamp: sample.presentationTimeStamp,packetDescriptions: nil,sampleBufferOut: &silent) == noErr else { return nil }
    return silent
}

// Accessed exclusively from the recorder's media queue, then finalized after capture stops.
final class AudioSink {
    let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private(set) var firstTime: CMTime?
    private(set) var failure: Error?
    /// Diagnostics only: the next sample fails like a broken device.
    var injectFailure = false
    init(url: URL) throws {
        writer = try AVAssetWriter(outputURL: url,fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio,outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,AVSampleRateKey: 48000,AVNumberOfChannelsKey: 1,AVEncoderBitRateKey: 128000])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.message("Mikrofon-Encoder nicht verfügbar.") }
        writer.add(input)
    }
    func append(_ sample: CMSampleBuffer) {
        guard failure == nil, CMSampleBufferDataIsReady(sample) else { return }
        if injectFailure { failure = RecorderError.message("Mikrofon-Encoder ausgefallen (Testfehler)."); return }
        if firstTime == nil {
            guard writer.startWriting() else { failure = writer.error; return }
            let time = sample.presentationTimeStamp; writer.startSession(atSourceTime: time); firstTime = time
        }
        if input.isReadyForMoreMediaData, !input.append(sample) { failure = writer.error ?? RecorderError.message("Mikrofonton konnte nicht geschrieben werden.") }
    }
    func finish() async throws {
        if let failure { writer.cancelWriting(); throw failure }
        guard firstTime != nil else { writer.cancelWriting(); throw RecorderError.message("Mikrofon lieferte keinen Ton. Geräteverbindung prüfen.") }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RecorderError.message("Mikrofonaufnahme konnte nicht abgeschlossen werden.") }
    }
}
