import AppKit
import AVFoundation
import RecorderCore

@MainActor enum InterfaceDiagnostics {
    static func run(arguments: [String]) async {
        guard let i = arguments.firstIndex(of: "--interface-check"),arguments.count > i+1 else { return }
        let root = URL(fileURLWithPath: arguments[i+1])
        // Test recordings must not appear in the user's “Deine Aufnahmen” list.
        let recent = UserDefaults.standard.object(forKey: "recentProjects")
        defer { UserDefaults.standard.set(recent,forKey: "recentProjects") }
        var lines: [String] = []
        func log(_ value: String) {
            lines.append(value)
            try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("interface-report.txt"),atomically: true,encoding: .utf8)
        }
        do {
            try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            log("START live interface acceptance \(Date().ISO8601Format())")
            let context = CGContext(data: nil,width: 480,height: 270,bitsPerComponent: 8,bytesPerRow: 480*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.8,green: 0.1,blue: 0.15,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: 480,height: 270))
            let source = context.makeImage()!
            for format in CanvasFormat.allCases {
                var style = Style(); style.format = format
                let worker = LiveCompositionWorker(mode: .studio,style: style)
                let result: CGImage? = await withCheckedContinuation { continuation in
                    worker.submit(CapturePreviewSample(image: source)) { image,_,_ in continuation.resume(returning: image) }
                }
                var project = Project(name: "Expected",duration: 1,width: source.width,height: source.height); project.style = style; project.mode = .studio
                let size = format.dimensions(height: 540)
                guard let result,let expected = FrameRenderer(project: project).image(screen: source,camera: nil,time: 0,width: size.0,height: size.1),
                      result.width == size.0,result.height == size.1,
                      result.dataProvider?.data as Data? == expected.dataProvider?.data as Data? else { throw RecorderError.message("Live composition differs from export renderer") }
                log("PASS \(format.rawValue) live composition equals export renderer pixels (\(size.0)×\(size.1))")
            }
            // Setup/recording preview: only screen (and camera), no background, margin or rounded corners.
            var portraitStyle = Style(); portraitStyle.format = .portrait
            let plainWorker = LiveCompositionWorker(mode: .studio,style: portraitStyle,plain: true)
            let plainFrame: CGImage? = await withCheckedContinuation { continuation in
                plainWorker.submit(CapturePreviewSample(image: source)) { image,_,_ in continuation.resume(returning: image) }
            }
            guard let plainFrame,abs(Double(plainFrame.width)/Double(plainFrame.height)-Double(source.width)/Double(source.height)) < 0.01 else { throw RecorderError.message("Plain preview must keep the source aspect ratio") }
            let probe = CGContext(data: nil,width: plainFrame.width,height: plainFrame.height,bitsPerComponent: 8,bytesPerRow: plainFrame.width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            probe.draw(plainFrame,in: CGRect(x: 0,y: 0,width: plainFrame.width,height: plainFrame.height))
            let bytes = probe.data!.assumingMemoryBound(to: UInt8.self)
            for (x,y) in [(0,0),(plainFrame.width-1,0),(0,plainFrame.height-1),(plainFrame.width-1,plainFrame.height-1)] {
                let i = y*plainFrame.width*4+x*4
                guard bytes[i] > 150,bytes[i+1] < 80,bytes[i+2] < 80 else { throw RecorderError.message("Plain preview shows background at corner \(x),\(y)") }
            }
            log("PASS plain live preview: screen only at source aspect \(plainFrame.width)×\(plainFrame.height), no background/corners even with 9:16 project format")
            // A busy camera/meter feed must not starve the less frequent screen snapshots.
            let coalesced = LiveCompositionWorker(mode: .studio,style: Style())
            await withCheckedContinuation { continuation in
                coalesced.submit(CapturePreviewSample(level: 0.2)) { _,_,_ in continuation.resume() }
            }
            let retained: CGImage? = await withCheckedContinuation { continuation in
                coalesced.submit(CapturePreviewSample(level: 0.4)) { image,_,_ in continuation.resume(returning: image) }
                coalesced.submit(CapturePreviewSample(image: source)) { _,_,_ in }
                for _ in 0..<100 { coalesced.submit(CapturePreviewSample(level: 0.6)) { _,_,_ in } }
            }
            guard retained != nil else { throw RecorderError.message("Screen snapshot lost during concurrent camera/meter updates") }
            log("PASS bounded coalescing retains source snapshots during high-rate device updates")
            guard arguments.contains("--real-capture") else { return }
            let camera = arguments.contains("--camera"), microphone = arguments.contains("--microphone")
            guard CGPreflightScreenCaptureAccess(),
                  !camera || AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                  !microphone || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                log("BLOCKED current-build screen/camera/microphone grants required"); return
            }
            let store = EditorStore(captureRoot: root)
            defer { store.suspendMonitor() }
            store.sources = try await ScreenRecorder.sources()
            store.selectedSource = store.sources.first(where: { $0.display != nil })?.id ?? ""
            store.withCamera = camera; store.withMicrophone = microphone; store.recordingTitle = "Live interface acceptance"
            store.updateMonitor()
            let previewDeadline = Date().addingTimeInterval(15)
            while (store.monitor.frame == nil || (camera && store.monitor.camera == nil)) && Date() < previewDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
            guard store.monitor.frame != nil,!camera || store.monitor.camera != nil else { throw RecorderError.message("Idle source/camera live preview missing: \(store.monitor.message)") }
            log("PASS idle audience composition and physical camera preview; microphone meter \(store.monitor.level)")
            let before = store.monitor.renderedFrames
            store.startRecording()
            let startDeadline = Date().addingTimeInterval(20)
            while store.phase == .preparing,Date() < startDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
            guard store.phase == .recording else { throw RecorderError.message(store.error ?? "Device handoff did not start recording") }
            log("PASS preview devices handed off to recorder; live controller receives recording session frames")
            // 10 s wall clock with a 2.5 s pause after 4 s: the timer stops, nothing is recorded, the pause becomes a cut.
            try await Task.sleep(nanoseconds: 4_000_000_000)
            store.togglePause()
            try await Task.sleep(nanoseconds: 300_000_000)
            let pausedAt = store.elapsed
            try await Task.sleep(nanoseconds: 2_200_000_000)
            guard store.paused, abs(store.elapsed-pausedAt) < 0.1 else { store.stopRecording(); throw RecorderError.message("Timer kept running while paused") }
            store.togglePause()
            try await Task.sleep(nanoseconds: 3_500_000_000)
            let frames = store.monitor.renderedFrames-before
            guard frames >= 20,store.monitor.frame != nil,!camera || store.monitor.camera != nil,(7.0...8.3).contains(store.elapsed) else { store.stopRecording(); throw RecorderError.message("Recording live preview/timer stalled (elapsed \(store.elapsed))") }
            log(String(format: "PASS %d preview updates during 10 s actual recording with a 2.5 s pause; timer froze while paused and shows %.2f s",frames,store.elapsed))
            store.stopRecording()
            let stopDeadline = Date().addingTimeInterval(20)
            while store.busy,Date() < stopDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
            guard store.phase == .idle,store.workspace == .edit,let project = store.project,let directory = store.directory,
                  !camera || project.hasCamera,!microphone || project.hasMicrophone == true else { throw RecorderError.message(store.error ?? "Stop did not open saved editor project") }
            try await Task.sleep(nanoseconds: 200_000_000)
            guard store.monitor.frame == nil,store.monitor.camera == nil else { throw RecorderError.message("Device preview remained active in editor") }
            let asset = AVURLAsset(url: directory.appendingPathComponent("screen.mov"))
            _ = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 9,preferredTimescale: 600))
            log("PASS Stop opens editor, idle preview clears, saved source decodes near end; camera \(project.hasCamera), microphone \(project.hasMicrophone == true)")
            guard project.cuts.count == 2 else { throw RecorderError.message("Pause did not become a cut: \(project.cuts.map { ($0.start,$0.end) })") }
            let gap = project.cuts[1].start-project.cuts[0].end
            guard (2.2...2.9).contains(gap), (6.8...8.4).contains(project.editedDuration) else { throw RecorderError.message("Pause cut has wrong size: gap \(gap), edited \(project.editedDuration)") }
            log(String(format: "PASS pause removed from the video: cut %.2f–%.2f s, edited length %.2f s of %.2f s recorded",project.cuts[0].end,project.cuts[1].start,project.editedDuration,project.duration))
            // Audio writers compact gaps; the pause must be filled with silence so sound stays in sync after it.
            var tracks: [String] = []
            for name in ["screen.mov"]+(project.hasMicrophone == true ? ["microphone.m4a"] : []) {
                guard let track = try await AVURLAsset(url: directory.appendingPathComponent(name)).loadTracks(withMediaType: .audio).first else { continue }
                let length = try await track.load(.timeRange).end.seconds
                guard abs(length-project.duration) < 0.35 else { throw RecorderError.message("\(name) audio is \(length) s for \(project.duration) s of picture: pause shifted the sound") }
                tracks.append(String(format: "%@ %.2f s",name,length))
            }
            log("PASS audio stays in sync across the pause (\(tracks.joined(separator: ", ")) for \(String(format: "%.2f",project.duration)) s of picture)")
        } catch { log("FAIL \(error.localizedDescription)") }
    }
}
