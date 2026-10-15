import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import AudioToolbox
import ImageIO
import RecorderCore

func makeFixture(at dir: URL,audioAmplitude: Double = 0.25) async throws -> Project {
    try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
    try await writeFixtureMovie(to: dir.appendingPathComponent("screen.mov"),camera: false,audioAmplitude: audioAmplitude)
    try await writeFixtureMovie(to: dir.appendingPathComponent("camera.mov"),camera: true)
    var p = Project(name: "Clean-room Demo",duration: 3,width: 640,height: 360,fps: 30)
    p.hasCamera = true; p.cameraOffset = 0.2
    for i in 0..<90 {
        let t = Double(i)
        let position = Point(0.25+t/180.0,0.35+sin(t/12.0)*0.15)
        p.pointer.append(PointerSample(time: t/30.0,position: position,clicked: i == 15 || i == 72))
    }
    p.zooms = Motion.automaticZooms(pointer: p.pointer,duration: p.duration)
    p.cuts = [Cut(start: 0,end: 0.75),Cut(start: 2,end: 3)]
    try p.save(to: dir)
    return p
}
private func writeFixtureMovie(to url: URL,camera: Bool,audioAmplitude: Double = 0.25) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url,fileType: .mov)
    let w = camera ? 320 : 640, h = 360
    let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: w,AVVideoHeightKey: h,AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000,AVVideoExpectedSourceFrameRateKey: 30]])
    input.expectsMediaDataInRealTime = true
    writer.add(input)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String: w,kCVPixelBufferHeightKey as String: h,kCVPixelBufferCGImageCompatibilityKey as String: true,kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
    var audio: AVAssetWriterInput?
    if !camera {
        let a = AVAssetWriterInput(mediaType: .audio,outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,AVSampleRateKey: 48000,AVNumberOfChannelsKey: 2,AVEncoderBitRateKey: 128000])
        a.expectsMediaDataInRealTime = true
        writer.add(a); audio = a
    }
    guard writer.startWriting() else { throw writer.error! }; writer.startSession(atSourceTime: .zero)
    for i in 0..<90 {
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing { throw writer.error ?? ExportError.message("Fixture video writer stopped") }; try await Task.sleep(nanoseconds: 1_000_000)
        }
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer) == 0)
        let b = buffer!
        CVPixelBufferLockBaseAddress(b,[])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b),width: w,height: h,bitsPerComponent: 8,bytesPerRow: CVPixelBufferGetBytesPerRow(b),space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
        let color: CGColor = camera ? CGColor(red: 0.05,green: 0.85,blue: 0.12,alpha: 1) : (i < 30 ? CGColor(red: 0.88,green: 0.12,blue: 0.08,alpha: 1) : CGColor(red: 0.08,green: 0.2,blue: 0.88,alpha: 1))
        ctx.setFillColor(color); ctx.fill(CGRect(x: 0,y: 0,width: w,height: h))
        ctx.setFillColor(CGColor(gray: 0.97,alpha: 1)); ctx.fill(CGRect(x: 0,y: h-40,width: w,height: 40))
        for j in 0..<3 { ctx.setFillColor(CGColor(red: 0.6+Double(j)*0.1,green: 0.5,blue: 0.7,alpha: 1)); ctx.fillEllipse(in: CGRect(x: 14+j*20,y: h-25,width: 10,height: 10)) }
        CVPixelBufferUnlockBaseAddress(b,[])
        precondition(adaptor.append(b,withPresentationTime: CMTime(value: Int64(i),timescale: 30)))
        if let audio {
            while !audio.isReadyForMoreMediaData { if writer.status != .writing { throw writer.error ?? ExportError.message("Fixture audio writer stopped") }; try await Task.sleep(nanoseconds: 1_000_000) }
            let sample = try makeAudio(start: i*1600,count: 1600,amplitude: audioAmplitude)
            precondition(audio.append(sample))
        }
    }
    input.markAsFinished(); audio?.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 3,timescale: 1))
    await writer.finishWriting(); guard writer.status == .completed else { throw writer.error! }
}
private func makeAudio(start: Int,count: Int,frequency: Double? = nil,amplitude: Double = 0.25) throws -> CMSampleBuffer {
    var samples = [Float](repeating: 0,count: count*2)
    for i in 0..<count {
        let t = Double(start+i)/48000, hz = frequency ?? (t < 1 ? 440.0 : 880.0)
        let value = Float(sin(2*Double.pi*hz*t)*amplitude)
        samples[i*2] = value; samples[i*2+1] = value
    }
    var block: CMBlockBuffer?
    precondition(CMBlockBufferCreateWithMemoryBlock(allocator: nil,memoryBlock: nil,blockLength: samples.count*4,blockAllocator: nil,customBlockSource: nil,offsetToData: 0,dataLength: samples.count*4,flags: 0,blockBufferOut: &block) == 0)
    samples.withUnsafeBytes { precondition(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!,blockBuffer: block!,offsetIntoDestination: 0,dataLength: $0.count) == 0) }
    var asbd = AudioStreamBasicDescription(mSampleRate: 48000,mFormatID: kAudioFormatLinearPCM,mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,mBytesPerPacket: 8,mFramesPerPacket: 1,mBytesPerFrame: 8,mChannelsPerFrame: 2,mBitsPerChannel: 32,mReserved: 0)
    var format: CMAudioFormatDescription?
    precondition(CMAudioFormatDescriptionCreate(allocator: nil,asbd: &asbd,layoutSize: 0,layout: nil,magicCookieSize: 0,magicCookie: nil,extensions: nil,formatDescriptionOut: &format) == 0)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1,timescale: 48000),presentationTimeStamp: CMTime(value: Int64(start),timescale: 48000),decodeTimeStamp: .invalid)
    var size = 8, buffer: CMSampleBuffer?
    precondition(CMSampleBufferCreateReady(allocator: nil,dataBuffer: block,formatDescription: format,sampleCount: count,sampleTimingEntryCount: 1,sampleTimingArray: &timing,sampleSizeEntryCount: 1,sampleSizeArray: &size,sampleBufferOut: &buffer) == 0)
    return buffer!
}
private func exportPixel(_ url: URL,at time: Double,x: Double,y: Double) async throws -> [UInt8] {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let image = try await generator.image(at: CMTime(seconds: time,preferredTimescale: 600)).image
    let ctx = CGContext(data: nil,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
    return pixel(ctx.makeImage()!,Int(x*Double(image.width)),Int(y*Double(image.height)))
}
func testExports(in root: URL) async throws {
    let dir = root.appendingPathComponent("fixture.rekord")
    var p = try await makeFixture(at: dir)
    // Keep center pixels stable to assert cut mapping independently from camera movement.
    p.zooms = []; p.style.showCursor = false
    for format in CanvasFormat.allCases {
        p.style.format = format
        let url = root.appendingPathComponent("format-\(format.rawValue.replacingOccurrences(of: ":",with: "x")).mp4")
        try await MovieExporter.export(project: p,directory: dir,to: url,height: 720,fps: 30)
        let asset = AVURLAsset(url: url), track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize), duration = try await asset.load(.duration).seconds
        let expected = format.dimensions(height: 720)
        XCTAssertEqual(Int(size.width),expected.0); XCTAssertEqual(Int(size.height),expected.1)
        XCTAssertEqual(duration,1.7667,accuracy: 0.05)
        let before = try await exportPixel(url,at: 0.2,x: 0.5,y: 0.5)
        let after = try await exportPixel(url,at: 1.1,x: 0.5,y: 0.5)
        precondition(before[0] > before[2]+100,"First retained range must be red")
        precondition(after[2] > after[0]+100,"Second retained range must be blue after cut")
        let webcam = try await exportPixel(url,at: 1.2,x: p.style.cameraPosition.x,y: p.style.cameraPosition.y)
        precondition(webcam[1] > 140 && webcam[0] < 80,"Webcam must be composited and synchronized")
        try await testAudio(url)
        print("PASS: \(format.rawValue) MP4 decoded: dimensions, duration, cuts, webcam, AAC tone timing")
    }
    // Export zoom/cursor motion and the public 1080p/60 option as well.
    p.zooms = Motion.automaticZooms(pointer: p.pointer,duration: p.duration); p.style.showCursor = true; p.style.format = .landscape
    let motionURL = root.appendingPathComponent("motion-1080p60.mp4")
    try await MovieExporter.export(project: p,directory: dir,to: motionURL,height: 1080,fps: 60)
    let motionTrack = try await AVURLAsset(url: motionURL).loadTracks(withMediaType: .video).first!
    // nominalFrameRate is an average estimate (track duration rounding can give 59.999996); check it within
    // 0.01 fps and check the actual cadence: frames advance in 1/60 s steps.
    XCTAssertEqual(Double(try await motionTrack.load(.nominalFrameRate)),60,accuracy: 0.01)
    let cadence = try await motionTrack.load(.minFrameDuration)
    XCTAssertEqual(cadence.seconds,1.0/60,accuracy: 0.0005)
    let fourK = root.appendingPathComponent("4k.mp4")
    p.cuts = [Cut(start: 0,end: 0.1)]
    try await MovieExporter.export(project: p,directory: dir,to: fourK,height: 2160,fps: 30)
    let fourKTrack = try await AVURLAsset(url: fourK).loadTracks(withMediaType: .video).first!
    XCTAssertEqual(Int(try await fourKTrack.load(.naturalSize).width),3840)
    // Background choices must survive the actual MP4 pipeline in both aspect ratios.
    var styled = p; styled.style.showCursor = false; styled.zooms = []; styled.style.shadow = 0
    var backdrop = BackdropSettings(kind: .solid); backdrop.start = RGB(0.1,0.7,0.8)
    for format in CanvasFormat.allCases {
        styled.style.format = format; styled.style.backdrop = backdrop
        let url = root.appendingPathComponent("custom-color-\(format.rawValue.replacingOccurrences(of: ":",with: "x")).mp4")
        try await MovieExporter.export(project: styled,directory: dir,to: url,height: 720,fps: 30)
        let color = try await exportPixel(url,at: 0,x: 0.01,y: 0.01)
        precondition(color[1] > 160 && color[2] > 180 && color[0] < 50,"Custom color must survive H.264 encoding")
    }
    let name = "background-export-test.png", photo = solidImage(red: 200,green: 150,blue: 20,width: 80,height: 80)
    let output = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,"public.png" as CFString,1,nil)!
    CGImageDestinationAddImage(output,photo,nil); precondition(CGImageDestinationFinalize(output))
    backdrop.kind = .image; backdrop.imageFile = name; backdrop.blur = 0.02; styled.style.backdrop = backdrop
    let photoURL = root.appendingPathComponent("custom-photo.mp4")
    try await MovieExporter.export(project: styled,directory: dir,to: photoURL,height: 720,fps: 30)
    let color = try await exportPixel(photoURL,at: 0,x: 0.01,y: 0.01)
    precondition(color[0] > 180 && color[1] > 130 && color[2] < 40,"Stored background image must survive H.264 encoding")
    print("PASS: custom color in both formats and project-relative blurred photo exported/decoded")
    try await testMicrophoneExport(project: try Project.load(from: dir),directory: dir,root: root)
    let loudDir = root.appendingPathComponent("loud-audio.rekord")
    let loudProject = try await makeFixture(at: loudDir,audioAmplitude: 0.92)
    try await testMicrophoneExport(project: loudProject,directory: loudDir,root: root,amplitude: 0.92)
    // A trim entirely before delayed narration is valid silent video, not an audio export failure.
    let silentDir = root.appendingPathComponent("silent-trim.rekord")
    try FileManager.default.createDirectory(at: silentDir,withIntermediateDirectories: true)
    try await writeFixtureMovie(to: silentDir.appendingPathComponent("screen.mov"),camera: true)
    let mic = silentDir.appendingPathComponent("microphone.m4a")
    try? FileManager.default.removeItem(at: mic)
    try FileManager.default.copyItem(at: dir.appendingPathComponent("microphone.m4a"),to: mic)
    var silent = Project(name: "Silent trim",duration: 3,width: 320,height: 360,fps: 30)
    silent.hasMicrophone = true; silent.microphoneOffset = 2; silent.cuts = [Cut(start: 0,end: 0.1)]
    let silentURL = root.appendingPathComponent("silent-trim.mp4")
    try await MovieExporter.export(project: silent,directory: silentDir,to: silentURL,height: 720,fps: 30)
    let silentTracks = try await AVURLAsset(url: silentURL).loadTracks(withMediaType: .audio)
    precondition(silentTracks.isEmpty,"A trim before narration must export as silent video")
    print("PASS: trim before delayed microphone exports valid silent MP4")
    // Cancellation must leave an existing destination untouched and remove work files.
    let cancelled = root.appendingPathComponent("cancelled.mp4"), sentinel = Data("existing destination".utf8)
    try sentinel.write(to: cancelled)
    let task = Task { try await MovieExporter.export(project: p,directory: dir,to: cancelled,height: 2160,fps: 60) }
    task.cancel()
    do { try await task.value; preconditionFailure("Cancellation expected") } catch is CancellationError {} catch { throw error }
    XCTAssertEqual(try Data(contentsOf: cancelled),sentinel)
    let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
    precondition(!contents.contains { $0.hasPrefix(".focus-export-") })
    print("PASS: 1080p60, 4K, cancellation preserves destination and removes temporary files")
}
private func audioTimeline(_ url: URL) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    precondition(tracks.count == 1,"AAC audio track missing")
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: tracks[0],outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,AVLinearPCMIsFloatKey: true,AVLinearPCMBitDepthKey: 32,AVLinearPCMIsNonInterleaved: false])
    reader.add(output); precondition(reader.startReading())
    var timeline = [Float](repeating: 0,count: 96000)
    while let sample = output.copyNextSampleBuffer(), let block = sample.dataBuffer {
        let count = CMBlockBufferGetDataLength(block)/4
        var values = [Float](repeating: 0,count: count)
        values.withUnsafeMutableBytes { precondition(CMBlockBufferCopyDataBytes(block,atOffset: 0,dataLength: $0.count,destination: $0.baseAddress!) == 0) }
        let start = Int((sample.presentationTimeStamp.seconds*48000).rounded())
        for i in 0..<count/2 where start+i >= 0 && start+i < timeline.count { timeline[start+i] = values[i*2] }
    }
    return timeline
}
private func testAudio(_ url: URL) async throws {
    let timeline = try await audioTimeline(url)
    func frequency(at second: Double) -> Double {
        let start = Int(second*48000), length = 4800
        var crossings = 0
        for i in (start+1)..<(start+length) where timeline[i-1] <= 0 && timeline[i] > 0 { crossings += 1 }
        return Double(crossings)*10
    }
    XCTAssertEqual(frequency(at: 0.2),440,accuracy: 20)
    XCTAssertEqual(frequency(at: 1.1),880,accuracy: 20)
}

private func testMicrophoneExport(project: Project,directory: URL,root: URL,amplitude: Double = 0.25) async throws {
    let url = directory.appendingPathComponent("microphone.m4a"); try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url,fileType: .m4a)
    let input = AVAssetWriterInput(mediaType: .audio,outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,AVSampleRateKey: 48000,AVNumberOfChannelsKey: 2,AVEncoderBitRateKey: 192000])
    writer.add(input); precondition(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    for i in 0..<90 {
        while !input.isReadyForMoreMediaData { if writer.status != .writing { throw writer.error! }; try await Task.sleep(nanoseconds: 1_000_000) }
        let sample = try makeAudio(start: i*1600,count: 1600,frequency: 660,amplitude: amplitude)
        precondition(input.append(sample))
    }
    input.markAsFinished(); await writer.finishWriting(); precondition(writer.status == .completed)
    var p = project; p.mode = .loom; p.hasMicrophone = true; p.microphoneOffset = 0.2; p.zooms = []
    let exported = root.appendingPathComponent(amplitude > 0.5 ? "loud-microphone-mix.mp4" : "microphone-mix.mp4")
    try await MovieExporter.export(project: p,directory: directory,to: exported,height: 720,fps: 30)
    let samples = try await audioTimeline(exported)
    func magnitude(_ hz: Double,at second: Double) -> Double {
        let start = Int(second*48000), count = 4800
        var real = 0.0, imaginary = 0.0
        for i in 0..<count {
            let phase = 2*Double.pi*hz*Double(i)/48000
            real += Double(samples[start+i])*cos(phase); imaginary += Double(samples[start+i])*sin(phase)
        }
        return sqrt(real*real+imaginary*imaginary)*2/Double(count)
    }
    precondition(magnitude(660,at: 0.02) < 0.02,"Microphone must respect delayed start")
    XCTAssertEqual(magnitude(660,at: 0.3),amplitude*0.75,accuracy: 0.025)
    XCTAssertEqual(magnitude(440,at: 0.3),amplitude*0.25,accuracy: 0.025)
    XCTAssertEqual(magnitude(880,at: 1.1),amplitude*0.25,accuracy: 0.025)
    XCTAssertEqual(magnitude(660,at: 1.1),amplitude*0.75,accuracy: 0.025)
    precondition(samples.allSatisfy { abs($0) < 0.98 },"Combined narration/system mix must retain peak headroom")
    print("PASS: delayed microphone + system audio mix, cut timing, gain and peak headroom (input amplitude \(amplitude))")
}
