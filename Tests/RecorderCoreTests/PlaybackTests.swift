import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import RecorderCore

// The editor's AVPlayer composition must show the same frames the exporter writes:
// decode it headlessly and compare every frame with the export renderer at the same time.
func testPlaybackComposition(in root: URL) async throws {
    let dir = root.appendingPathComponent("playback.rekord")
    let project = try await makeFixture(at: dir)
    let timeline = try await PlaybackTimeline.make(project: project,directory: dir)
    XCTAssertEqual(timeline.composition.duration.seconds,project.editedDuration,accuracy: 0.04)
    // Landscape without zoom checks cut colours at the frame centre; portrait keeps zoom and cursor for parity.
    for format in CanvasFormat.allCases {
        var p = project; p.style.format = format
        let checksColours = format == .landscape
        if checksColours { p.zooms = []; p.style.showCursor = false }
        let video = timeline.videoComposition(project: p,backgroundImage: nil,height: 360)
        let reader = try AVAssetReader(asset: timeline.composition)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await timeline.composition.loadTracks(withMediaType: .video),videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = video
        precondition(reader.canAdd(output)); reader.add(output)
        let audio = AVAssetReaderAudioMixOutput(audioTracks: try await timeline.composition.loadTracks(withMediaType: .audio),audioSettings: nil)
        audio.audioMix = timeline.audioMix
        precondition(reader.canAdd(audio)); reader.add(audio)
        precondition(reader.startReading(),"Playback composition must be readable: \(String(describing: reader.error))")
        let screen = try await VideoFrames(url: dir.appendingPathComponent("screen.mov"))
        let camera = try await VideoFrames(url: dir.appendingPathComponent("camera.mov"))
        let renderer = FrameRenderer(project: p)
        let (w,h) = p.style.format.dimensions(height: 360)
        let reference = makeOutputBuffer(width: w,height: h)
        var frames = 0, worst = 0.0, total = 0.0
        var colours: [(Double,[UInt8])] = []
        let clock = Date()
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = sample.imageBuffer else { continue }
            let t = sample.presentationTimeStamp.seconds, source = p.sourceTime(at: t)
            XCTAssertEqual(CVPixelBufferGetWidth(buffer),w); XCTAssertEqual(CVPixelBufferGetHeight(buffer),h)
            let screenImage = renderer.cgImage(from: try screen.buffer(at: source)!)!
            let ct = source-p.cameraOffset
            let cameraImage = ct >= 0 && ct < camera.duration ? try camera.buffer(at: ct).flatMap { renderer.cgImage(from: $0) } : nil
            precondition(renderer.render(to: reference,screen: screenImage,camera: cameraImage,time: source))
            let difference = meanDifference(buffer,reference)
            worst = max(worst,difference); total += difference; frames += 1
            colours.append((t,centre(buffer)))
        }
        let seconds = Date().timeIntervalSince(clock)
        var audioSamples = 0
        while let sample = audio.copyNextSampleBuffer() { audioSamples += CMSampleBufferGetNumSamples(sample) }
        precondition(reader.status == .completed,"Composition decode failed: \(String(describing: reader.error))")
        precondition(frames >= Int(p.editedDuration*30)-2,"Expected about \(Int(p.editedDuration*30)) frames, got \(frames)")
        precondition(worst < 1.0,"Player frames must match export renderer (worst mean difference \(worst))")
        // Cut mapping: red before the cut, blue after it, as in the exported MP4.
        if checksColours {
            let early = colours.first { $0.0 >= 0.2 }!.1, late = colours.first { $0.0 >= 1.1 }!.1
            precondition(early[2] > early[0]+100 && late[0] > late[2]+100,"Composition must follow retained cut ranges (BGRA \(early) / \(late))")
        }
        XCTAssertEqual(Double(audioSamples)/48000,p.editedDuration,accuracy: 0.08)
        print(String(format: "PASS: %@%@ editor playback composition = export renderer (%d frames, mean diff %.3f, worst %.3f), cut-aware audio %.2f s, %.0f fps decode+compose",format.rawValue,checksColours ? " cut colours," : " zoom+cursor,",frames,total/Double(frames),worst,Double(audioSamples)/48000,Double(frames)/seconds))
    }
}

private func meanDifference(_ a: CVPixelBuffer,_ b: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(a,.readOnly); CVPixelBufferLockBaseAddress(b,.readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a,.readOnly); CVPixelBufferUnlockBaseAddress(b,.readOnly) }
    let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
    let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self), pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let sa = CVPixelBufferGetBytesPerRow(a), sb = CVPixelBufferGetBytesPerRow(b)
    var sum = 0
    for y in 0..<h { for x in 0..<w*4 where x % 4 != 3 { sum += abs(Int(pa[y*sa+x])-Int(pb[y*sb+x])) } }
    return Double(sum)/Double(w*h*3)
}

private func centre(_ buffer: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer,.readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
    let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let i = CVPixelBufferGetHeight(buffer)/2*CVPixelBufferGetBytesPerRow(buffer)+CVPixelBufferGetWidth(buffer)/2*4
    return [p[i],p[i+1],p[i+2]]
}

/// `--playback-benchmark <project.rekord>`: decode+compose throughput of the editor composition (read-only).
func benchmarkPlayback(project directory: URL) async throws {
    let project = try Project.load(from: directory)
    let timeline = try await PlaybackTimeline.make(project: project,directory: directory)
    for height in [720,1080] {
        let reader = try AVAssetReader(asset: timeline.composition)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await timeline.composition.loadTracks(withMediaType: .video),videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = timeline.videoComposition(project: project,backgroundImage: try BackgroundAsset.load(project: project,directory: directory),height: height)
        reader.add(output); precondition(reader.startReading())
        let clock = Date(); var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        precondition(reader.status == .completed,"\(String(describing: reader.error))")
        let fps = Double(frames)/Date().timeIntervalSince(clock)
        print(String(format: "BENCH playback %dp: %d frames of %.2f s (%d×%d source, %d fps) composed at %.0f fps = %.1f× real time",height,frames,project.editedDuration,project.width,project.height,project.fps,fps,fps/Double(project.fps)))
    }
}

/// `--export-benchmark <project.rekord>`: full MP4 export timing on a real recording (output in a temp directory).
func benchmarkExport(project directory: URL) async throws {
    let project = try Project.load(from: directory)
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("focus-export-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: out,withIntermediateDirectories: true)
    let keep = ProcessInfo.processInfo.environment["REKORD_BENCH_KEEP"]
    defer { if let keep { try? FileManager.default.removeItem(atPath: keep); try? FileManager.default.moveItem(atPath: out.path,toPath: keep) } else { try? FileManager.default.removeItem(at: out) } }
    for (height,fps) in [(1080,60),(2160,60)] {
        let clock = Date()
        try await MovieExporter.export(project: project,directory: directory,to: out.appendingPathComponent("bench-\(height).mp4"),height: height,fps: fps)
        let seconds = Date().timeIntervalSince(clock)
        print(String(format: "BENCH export %dp%d: %.2f s video in %.2f s = %.1f× real time",height,fps,project.editedDuration,seconds,project.editedDuration/seconds))
    }
}
