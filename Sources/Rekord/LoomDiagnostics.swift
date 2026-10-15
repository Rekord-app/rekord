import AppKit
import AVFoundation
import RecorderCore

@MainActor enum LoomDiagnostics {
    static func run(arguments: [String]) async {
        guard let i = arguments.firstIndex(of: "--loom-check"),arguments.count > i+1,
              let c = arguments.firstIndex(of: "--share-connection"),arguments.count > c+1 else { return }
        let root = URL(fileURLWithPath: arguments[i+1])
        var lines: [String] = []
        func log(_ value: String) { lines.append(value); try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("loom-report.txt"),atomically: true,encoding: .utf8); print(value) }
        do {
            try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            log("START native Loom acceptance \(Date().ISO8601Format())")
            let existingProject: URL? = arguments.firstIndex(of: "--project").flatMap { arguments.count > $0+1 ? URL(fileURLWithPath: arguments[$0+1]) : nil }
            let microphone = arguments.contains("--microphone")
            if existingProject == nil {
                var blocked = false
                if !CGPreflightScreenCaptureAccess() { log("BLOCKED screen TCC permission"); blocked = true }
                if AVCaptureDevice.authorizationStatus(for: .video) != .authorized { log("BLOCKED camera permission for physical webcam acceptance"); blocked = true }
                if microphone, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    log("BLOCKED microphone permission; enable Mikrofon before real narration acceptance"); blocked = true
                }
                if blocked { return }
            }
            struct Connection: Decodable { let baseURL: URL; let token: String }
            let connection = try JSONDecoder().decode(Connection.self,from: Data(contentsOf: URL(fileURLWithPath: arguments[c+1])))
            guard ["127.0.0.1","localhost"].contains(connection.baseURL.host ?? "") else { throw ShareError.message("Acceptance fixture requires loopback sharing, so real test footage is never published externally.") }
            let previous = UserDefaults.standard.string(forKey: "shareServer")
            let recent = UserDefaults.standard.stringArray(forKey: "recentProjects")
            let oldToken = try ShareKeychain.read(server: connection.baseURL.absoluteString)
            let clipboard = NSPasteboard.general.pasteboardItems?.map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem(); for type in item.types { if let data = item.data(forType: type) { copy.setData(data,forType: type) } }; return copy
            }
            try ShareKeychain.save(connection.token,server: connection.baseURL.absoluteString)
            UserDefaults.standard.set(connection.baseURL.absoluteString,forKey: "shareServer")
            defer {
                UserDefaults.standard.set(previous,forKey: "shareServer"); UserDefaults.standard.set(recent,forKey: "recentProjects")
                if let oldToken { try? ShareKeychain.save(oldToken,server: connection.baseURL.absoluteString) } else { ShareKeychain.remove(server: connection.baseURL.absoluteString) }
                NSPasteboard.general.clearContents(); if let clipboard { NSPasteboard.general.writeObjects(clipboard) }
            }
            let store = EditorStore(captureRoot: root)
            store.shareConfigured = true; store.recordingMode = .loom; store.recordingTitle = "Native Loom acceptance"
            store.captureFPS = 30; store.withCamera = true; store.withMicrophone = microphone; store.withAudio = true
            let stop: Date
            if let existingProject {
                let copy = root.appendingPathComponent("source.rekord")
                try FileManager.default.copyItem(at: existingProject,to: copy)
                var project = try Project.load(from: copy)
                project.mode = .loom; project.zooms = []; project.style.padding = 0; project.style.cornerRadius = 0; project.style.shadow = 0
                try project.save(to: copy)
                if arguments.contains("--realtime-fixture") {
                    let source = try await VideoFrames(url: copy.appendingPathComponent("screen.mov"))
                    let camera = project.hasCamera ? try await VideoFrames(url: copy.appendingPathComponent("camera.mov")) : nil
                    let sink = try LoomSink(url: copy.appendingPathComponent("loom.mov"))
                    let motion = MotionTrack(samples: project.pointer,smoothing: 0)
                    let clock = Date()
                    for frame in 0..<Int(ceil(project.duration*30)) {
                        let t = Double(frame)/30
                        let wait = t-Date().timeIntervalSince(clock)
                        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait*1_000_000_000)) }
                        guard let screen = try source.buffer(at: t) else { throw ShareError.message("Fixture screen frame missing") }
                        let sample = motion.sample(at: t)
                        let camTime = t-project.cameraOffset
                        let cam = camTime >= 0 ? try camera?.buffer(at: camTime) : nil
                        sink.append(screen: screen,camera: cam,pointer: sample?.visible == true ? sample?.position : nil,time: CMTime(seconds: t,preferredTimescale: 60000),start: .zero)
                    }
                    try await sink.finish(at: CMTime(seconds: project.duration,preferredTimescale: 60000))
                    guard sink.dropped < 3 else { throw ShareError.message("Realtime fixture dropped too many frames: \(sink.dropped)") }
                    try project.fingerprint().write(to: copy.appendingPathComponent("loom-project.txt"),atomically: true,encoding: .utf8)
                    log("PASS realtime Loom encoding of verified screen/camera fixture; dropped \(sink.dropped) frames")
                }
                store.load(project: project,directory: copy)
                stop = Date(); store.share()
                log("Using previously verified real capture; this run tests native prepare/upload/link, not a new recording")
            } else {
                store.sources = try await ScreenRecorder.sources(); store.selectedSource = store.sources.first(where: { $0.display != nil })?.id ?? ""
                store.startRecording()
                let preparationDeadline = Date().addingTimeInterval(20)
                while store.phase == .preparing && Date() < preparationDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
                guard store.phase == .recording else { throw ShareError.message(store.error ?? "Capture did not start") }
                log("PASS capture started; camera warm-up completed before screen clock")
                try await Task.sleep(nanoseconds: 4_000_000_000)
                stop = Date(); store.stopRecording()
            }
            let sharingDeadline = Date().addingTimeInterval(180)
            while store.busy && Date() < sharingDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
            guard !store.busy,let receipt = store.shareReceipt,let directory = store.directory,let project = store.project else { throw ShareError.message(store.error ?? "No automatic share receipt") }
            guard project.recordingMode == .loom,project.zooms.isEmpty,project.hasCamera,
                  !microphone || project.hasMicrophone == true,
                  NSPasteboard.general.string(forType: .string) == receipt.video.url.absoluteString else { throw ShareError.message("Loom mode/metadata/link clipboard mismatch") }
            log("PASS native MP4 preparation → upload → clipboard link in \(String(format:"%.2f",Date().timeIntervalSince(stop)))s")
            let media = receipt.server.appendingPathComponent("media/\(receipt.video.id)")
            let (download,response) = try await URLSession.shared.data(from: media)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ShareError.message("Shared media download failed") }
            let movie = root.appendingPathComponent("downloaded.mp4"); try download.write(to: movie)
            guard try fileHash(movie) == receipt.video.sha256 else { throw ShareError.message("Shared playback bytes differ from upload") }
            let asset = AVURLAsset(url: movie), track = try await asset.loadTracks(withMediaType: .video).first!
            let size = try await track.load(.naturalSize)
            _ = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 2,preferredTimescale: 600))
            log("PASS downloaded MP4 decodes \(Int(size.width))×\(Int(size.height)); raw source \(project.width)×\(project.height), camera offset \(project.cameraOffset)s, mic \(project.hasMicrophone == true)")
            // Repeating the same upload must recover the existing capability after a lost response.
            let client = try ShareClient(baseURL: connection.baseURL,token: connection.token)
            let retry = try await client.upload(file: directory.appendingPathComponent("share.mp4"),title: project.name)
            guard retry.id == receipt.video.id else { throw ShareError.message("Retry produced a duplicate video") }
            store.revokeShare()
            let revokeDeadline = Date().addingTimeInterval(15)
            while store.busy && Date() < revokeDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
            let (_,revoked) = try await URLSession.shared.data(from: receipt.video.url)
            guard store.shareReceipt == nil,(revoked as? HTTPURLResponse)?.statusCode == 404 else { throw ShareError.message("Revocation failed") }
            log("PASS duplicate-free retry and native link revocation; local recording preserved")
        } catch { log("FAIL \(error.localizedDescription)") }
    }
}
