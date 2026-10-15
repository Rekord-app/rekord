import AppKit
import AVFoundation
import ScreenCaptureKit
import RecorderCore

// Explicit developer diagnostic mode. Never runs during a normal app launch.
@MainActor enum Diagnostics {
    static func run(arguments: [String]) async {
        guard let index = arguments.firstIndex(of: "--diagnostics"),arguments.count > index+1 else { return }
        let root = URL(fileURLWithPath: arguments[index+1])
        var lines: [String] = []
        func log(_ message: String) { lines.append(message); print(message); try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("capture-report.txt"),atomically: true,encoding: .utf8) }
        do {
            try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            log("START diagnostics \(Date().ISO8601Format())")
            let fixture = root.deletingLastPathComponent().appendingPathComponent("qa/fixture.rekord/screen.mov")
            if FileManager.default.fileExists(atPath: fixture.path) {
                let asset = AVURLAsset(url: fixture)
                let track = try await asset.loadTracks(withMediaType: .video).first!
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track,outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(output); guard reader.startReading(),let sample = output.copyNextSampleBuffer() else { throw RecorderError.message("Diagnostic source unavailable") }
                let size = try await track.load(.naturalSize)
                let file = root.appendingPathComponent("static-tail.mov"); try? FileManager.default.removeItem(at: file)
                let sink = try MovieSink(url: file,width: Int(size.width),height: Int(size.height),fps: 30,audio: false)
                _ = sink.appendVideo(sample)
                try await sink.finish(at: sample.presentationTimeStamp+CMTime(value: 3,timescale: 1))
                let duration = try await AVURLAsset(url: file).load(.duration).seconds
                guard abs(duration-3) < 0.05 else { throw RecorderError.message("Static tail duration incorrect: \(duration)") }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
                _ = try await generator.image(at: CMTime(seconds: 2.9,preferredTimescale: 600))
                log("PASS static-screen tail: \(duration)s from one captured frame; last frame decodes")
            }
            guard arguments.contains("--real-capture") else { log("SKIP real capture: pass --real-capture explicitly"); return }
            guard CGPreflightScreenCaptureAccess() else { log("BLOCKED screen capture: macOS TCC permission not granted"); return }
            let sources = try await ScreenRecorder.sources()
            let camera = arguments.contains("--camera")
            if camera, AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                log("BLOCKED webcam: camera permission not granted; use Webcam toggle to request it"); return
            }
            guard let display = sources.first(where: { $0.display != nil }) else { throw RecorderError.message("No display") }
            // 16:9 area below the menu bar of the main display, as offered for taller Mac screens.
            var area: CaptureSource?
            if let scDisplay = display.display {
                let width = Double(scDisplay.width), height = min(Double(scDisplay.height)-37,width*9/16)
                area = CaptureSource.area(CGRect(x: 0,y: 37,width: height*16/9,height: height),on: scDisplay)
            }
            for (kind,source) in [("display",display),("window",sources.first(where: { $0.window != nil })),("area",area)].compactMap({ kind,source in source.map { (kind,$0) } }) {
                let dir = root.appendingPathComponent("\(kind).rekord")
                if FileManager.default.fileExists(atPath: dir.path) { log("SKIP existing \(dir.lastPathComponent); use a fresh diagnostic directory"); continue }
                try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
                let recorder = ScreenRecorder()
                try await recorder.start(source: source,directory: dir,fps: 60,withCamera: camera,withAudio: true)
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let project = try await recorder.stop(name: "Capture check \(kind)")
                try project.save(to: dir)
                let asset = AVURLAsset(url: dir.appendingPathComponent("screen.mov"))
                let track = try await asset.loadTracks(withMediaType: .video).first!
                let size = try await track.load(.naturalSize)
                let generator = AVAssetImageGenerator(asset: asset)
                _ = try await generator.image(at: CMTime(seconds: 1,preferredTimescale: 600))
                guard project.duration >= 2.5,project.pointer.count >= 100 else { throw RecorderError.message("Capture duration/pointer samples too short") }
                if camera, !project.hasCamera { throw RecorderError.message("Camera requested but no webcam frames") }
                try await MovieExporter.export(project: project,directory: dir,to: root.appendingPathComponent("\(kind).mp4"),height: 720)
                if kind == "area" {
                    guard abs(size.width/size.height-16.0/9.0) < 0.01 else { throw RecorderError.message("Area recording is not 16:9: \(size)") }
                }
                log("PASS \(kind): \(Int(size.width))×\(Int(size.height)), \(project.duration)s, \(project.pointer.count) pointer samples, webcam \(project.hasCamera), MP4 exported")
            }
        } catch { log("FAIL \(error.localizedDescription)") }
    }
}
