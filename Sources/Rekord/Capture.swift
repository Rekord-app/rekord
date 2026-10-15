import AppKit
@preconcurrency import AVFoundation
import ScreenCaptureKit
import RecorderCore

struct CaptureSource: Identifiable {
    let id: String
    let title: String
    let display: SCDisplay?
    let window: SCWindow?
    /// Part of the display to record, in display points (origin top-left); nil records the whole display.
    var area: CGRect? = nil
    /// Captured region in global screen coordinates (origin top-left), used to map the pointer.
    var frame: CGRect {
        if let window { return window.frame }
        guard let display else { return .zero }
        guard let area else { return display.frame }
        return area.offsetBy(dx: display.frame.minX,dy: display.frame.minY)
    }
    static func area(_ rect: CGRect,on display: SCDisplay) -> CaptureSource {
        let r = rect.integral
        return CaptureSource(id: "area-\(display.displayID)-\(Int(r.minX))-\(Int(r.minY))-\(Int(r.width))-\(Int(r.height))",title: "Bereich \(Int(r.width))×\(Int(r.height))",display: display,window: nil,area: r)
    }
}
enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let s): return s } }
}

// All writer state is confined to the recorder's serial media queue.
final class MovieSink {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput?
    private(set) var firstTime: CMTime?
    private(set) var duration = 0.0
    private(set) var frames = 0
    private(set) var dropped = 0
    private(set) var failure: Error?
    let fps: Int
    private var lastVideo: CMSampleBuffer?
    init(url: URL, width: Int, height: Int, fps: Int, audio: Bool) throws {
        self.fps = fps
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Fragmented while writing: if the app dies, the movie stays readable up to the last fragment.
        writer.movieFragmentInterval = CMTime(seconds: 4, preferredTimescale: 600)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoColorPropertiesKey: videoColorProperties,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(12_000_000, width*height*fps/5), AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps*2]])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecorderError.message("Video-Encoder nicht verfügbar.") }
        writer.add(video)
        if audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.message("Audio-Encoder nicht verfügbar.") }
            writer.add(input); self.audio = input
        } else { self.audio = nil }
    }
    func appendVideo(_ sample: CMSampleBuffer) -> Double? {
        guard failure == nil, CMSampleBufferDataIsReady(sample) else { return nil }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if firstTime == nil {
            guard writer.startWriting() else { failure = writer.error; return nil }
            writer.startSession(atSourceTime: time); firstTime = time
        }
        guard writer.status == .writing, let firstTime else { return nil }
        let seconds = CMTimeGetSeconds(time-firstTime)
        if video.isReadyForMoreMediaData {
            if !video.append(sample) { failure = writer.error ?? RecorderError.message("Videoframe konnte nicht geschrieben werden.") }
            else { frames += 1; duration = seconds + 1/Double(fps); lastVideo = sample }
        } else { dropped += 1 }
        return seconds
    }
    func appendAudio(_ sample: CMSampleBuffer) {
        guard failure == nil, let firstTime, let audio, writer.status == .writing,
              CMSampleBufferGetPresentationTimeStamp(sample) >= firstTime else { return }
        if audio.isReadyForMoreMediaData, !audio.append(sample) { failure = writer.error }
    }
    func finish(at endTime: CMTime) async throws {
        if let failure { writer.cancelWriting(); throw failure }
        guard firstTime != nil, frames > 0 else { writer.cancelWriting(); throw RecorderError.message("Keine Videoframes empfangen. Bildschirmfreigabe und Quelle prüfen.") }
        if let firstTime, let lastVideo {
            let endTime = max(endTime,firstTime+CMTime(seconds: duration,preferredTimescale: 60000))
            let finalTime = max(firstTime,endTime-CMTime(value: 1,timescale: Int32(fps)))
            if finalTime > lastVideo.presentationTimeStamp {
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1,timescale: Int32(fps)),presentationTimeStamp: finalTime,decodeTimeStamp: .invalid)
                var held: CMSampleBuffer?
                let result = CMSampleBufferCreateCopyWithNewTiming(allocator: nil,sampleBuffer: lastVideo,sampleTimingEntryCount: 1,sampleTimingArray: &timing,sampleBufferOut: &held)
                if result == noErr, let held {
                    let deadline = Date().addingTimeInterval(5)
                    while !video.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
                    guard video.isReadyForMoreMediaData, video.append(held) else { throw writer.error ?? RecorderError.message("Letzter Aufnahmeframe konnte nicht geschrieben werden.") }
                    duration = (finalTime-firstTime).seconds+1/Double(fps)
                }
            }
            writer.endSession(atSourceTime: max(endTime,firstTime+CMTime(value: 1,timescale: Int32(fps))))
        }
        video.markAsFinished(); audio?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RecorderError.message("Aufnahme konnte nicht abgeschlossen werden.") }
    }
}

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.sapunov.rekord.media", qos: .userInitiated)
    private var stream: SCStream?
    private var pointerTimer: DispatchSourceTimer?
    @MainActor private var clickMonitor: Any?
    private var clicksViaEvents = false
    private var session: AVCaptureSession?
    private var screenSink: MovieSink?
    private var cameraSink: MovieSink?
    private var microphoneSink: AudioSink?
    private var loomSink: LoomSink?
    private var latestScreen: CVPixelBuffer?
    private var latestCamera: CVPixelBuffer?
    private var wantsCamera = false
    private var cameraReady = false
    private var microphoneReady = false
    private var source: CaptureSource?
    private var samples: [PointerSample] = []
    private var lastButton = false
    private var lastFrameRefresh = -1.0
    private var bounds = CGRect.zero
    private var recording = false
    // Paused time is not written to any track; on Stop each pause becomes a cut in the project.
    private var paused = false
    private var pauses: [(start: CMTime,end: CMTime?)] = []
    private var streamFailure: Error?
    private var dimensions = (0,0)
    private var fps = 60
    private(set) var warning: String?
    private(set) var quickShareReady = false
    /// Project data the crash journal starts from (mode, look, title); set before start.
    var recoveryTemplate: Project?
    private var journal: RecoveryJournal?
    private var journalDirectory: URL?
    private var lastCheckpoint = 0.0
    private var reportedProblems: Set<String> = []
    /// Camera or microphone failed while the screen keeps recording (shown, recording continues).
    var onTrackProblem: (@Sendable (String) -> Void)?
    /// Diagnostics only: "microphone" makes the microphone encoder fail during the take.
    nonisolated(unsafe) static var faultInjection: String?
    /// Receives the configured camera session before warm-up, so preview layers attach before the
    /// screen clock starts instead of reconfiguring the session mid-recording.
    var onCameraSession: (@MainActor (AVCaptureSession) -> Void)?
    var onUnexpectedStop: (@Sendable (String) -> Void)?
    var onPreview: (@Sendable (CapturePreviewSample) -> Void)?
    /// Guide mode: every click with its global location (points, origin top-left), recording time and button.
    var onClick: (@Sendable (CGPoint,Double,Bool) -> Void)?
    /// Captured region in global points and the recorded pixel size (valid after `start`).
    var geometry: (bounds: CGRect,dimensions: (Int,Int)) { (bounds,dimensions) }
    private var microphonePower = 0.0

    static func sources() async throws -> [CaptureSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let displays = content.displays.enumerated().map { CaptureSource(id: "display-\($0.element.displayID)", title: "Bildschirm \($0.offset+1) · \($0.element.width)×\($0.element.height)", display: $0.element, window: nil) }
        let windows = content.windows.filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 100 && $0.frame.height > 80 && !($0.title ?? "").isEmpty }.sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }.map { CaptureSource(id: "window-\($0.windowID)", title: "\($0.owningApplication?.applicationName ?? "App") — \($0.title ?? "Fenster")", display: nil, window: $0) }
        return displays + windows
    }
    static func contentFilter(for source: CaptureSource) async throws -> SCContentFilter {
        if let window = source.window { return SCContentFilter(desktopIndependentWindow: window) }
        if let display = source.display {
            let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly: true)
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            return SCContentFilter(display: display,excludingApplications: own,exceptingWindows: [])
        }
        throw RecorderError.message("Keine Aufnahmequelle ausgewählt.")
    }
    /// 16:9 crop chosen at start for a whole MacBook display (menu bar and Dock removed); applied to Loom live.
    private(set) var autoCrop: CropRect?
    func start(source: CaptureSource, directory: URL, fps: Int, withCamera: Bool, withAudio: Bool, withMicrophone: Bool = false,mode: RecordingMode = .studio,cameraID: String = "",microphoneID: String = "",widescreenMenuBar: Double? = nil) async throws {
        await withCheckedContinuation { continuation in queue.async {
            self.cameraReady = false; self.microphoneReady = false; self.cameraURL = nil; self.cameraFailure = nil; self.cameraFrames = 0
            self.latestScreen = nil; self.latestCamera = nil
            continuation.resume()
        } }
        self.source = source; self.fps = fps; bounds = source.frame
        samples = []; lastButton = false; lastFrameRefresh = -1; streamFailure = nil; warning = nil; quickShareReady = false
        journalDirectory = directory; lastCheckpoint = 0; reportedProblems = []
        journal = recoveryTemplate.map { RecoveryJournal(directory: directory,template: $0) }
        await withCheckedContinuation { continuation in queue.async { self.paused = false; self.pauses = []; continuation.resume() } }
        microphonePower = 0
        let filter = try await Self.contentFilter(for: source)
        let size = source.area?.size ?? filter.contentRect.size
        let scale = min(Double(filter.pointPixelScale), 4096.0/Double(max(1,max(size.width,size.height))))
        let width = max(2, Int(size.width*scale)/2*2), height = max(2, Int(size.height*scale)/2*2)
        dimensions = (width,height)
        autoCrop = source.window == nil && source.area == nil ? widescreenMenuBar.flatMap { CropRect.automaticWidescreen(sourceWidth: width,sourceHeight: height,menuBar: $0) } : nil
        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        if let area = source.area { config.sourceRect = area }
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps)); config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA; config.colorSpaceName = CGColorSpace.sRGB; config.showsCursor = false
        config.ignoreShadowsSingleWindow = true; config.scalesToFit = true; config.preservesAspectRatio = true
        config.capturesAudio = withAudio; config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000; config.channelCount = 2
        screenSink = try MovieSink(url: directory.appendingPathComponent("screen.mov"), width: width, height: height, fps: fps, audio: withAudio)
        do {
            if mode == .loom { loomSink = try LoomSink(url: directory.appendingPathComponent("loom.mov"),crop: autoCrop) }
            wantsCamera = withCamera
            if withCamera || withMicrophone { try await startDevices(directory: directory,withCamera: withCamera,withMicrophone: withMicrophone,cameraID: cameraID,microphoneID: microphoneID) }
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if withAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            self.stream = stream
            await installClickMonitor()
            await withCheckedContinuation { continuation in queue.async { self.recording = true
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(),repeating: 1.0/Double(fps))
                timer.setEventHandler { [weak self] in self?.samplePointer() }
                self.pointerTimer = timer; timer.resume(); continuation.resume() } }
            try await stream.startCapture()
        } catch {
            await abort(); throw error
        }
    }
    private func startDevices(directory: URL,withCamera: Bool,withMicrophone: Bool,cameraID: String,microphoneID: String) async throws {
        if withCamera, !(await AVCaptureDevice.requestAccess(for: .video)) { throw RecorderError.message("Kamerazugriff fehlt. In Datenschutz & Sicherheit → Kamera freigeben.") }
        if withMicrophone, !(await AVCaptureDevice.requestAccess(for: .audio)) { throw RecorderError.message("Mikrofonzugriff fehlt. In Datenschutz & Sicherheit → Mikrofon freigeben.") }
        let session = AVCaptureSession(); session.beginConfiguration()
        if withCamera {
            guard let device = CaptureDevices.camera(id: cameraID) else { throw RecorderError.message("Keine Webcam angeschlossen.") }
            cameraDevice = device
            session.sessionPreset = .hd1280x720
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecorderError.message("Webcam kann nicht geöffnet werden.") }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true; output.setSampleBufferDelegate(self,queue: queue)
            guard session.canAddOutput(output) else { throw RecorderError.message("Webcam-Ausgabe nicht verfügbar.") }
            session.addOutput(output); cameraURL = directory.appendingPathComponent("camera.mov")
        }
        if withMicrophone {
            guard let device = CaptureDevices.microphone(id: microphoneID) else { throw RecorderError.message("Kein Mikrofon angeschlossen.") }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecorderError.message("Mikrofon kann nicht geöffnet werden.") }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput(); output.setSampleBufferDelegate(self,queue: queue)
            guard session.canAddOutput(output) else { throw RecorderError.message("Mikrofon-Ausgabe nicht verfügbar.") }
            session.addOutput(output)
            microphoneSink = try AudioSink(url: directory.appendingPathComponent("microphone.m4a"))
            microphoneSink?.injectFailure = Self.faultInjection == "microphone"
        }
        session.commitConfiguration(); self.session = session
        if withCamera, let onCameraSession { await MainActor.run { onCameraSession(session) } }
        await withCheckedContinuation { continuation in queue.async { session.startRunning(); continuation.resume() } }
        // Warm up hardware before the screen clock starts, avoiding a late webcam/mic overlay. A freshly
        // opened camera delivers dark frames while auto-exposure converges, so also wait (bounded) until
        // exposure and white balance have settled.
        let deadline = Date().addingTimeInterval(8)
        var deviceReady: Date?
        while Date() < deadline {
            let (ready,frames) = await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: ((!withCamera || self.cameraReady) && (!withMicrophone || self.microphoneReady),self.cameraFrames)) } }
            if ready {
                deviceReady = deviceReady ?? Date()
                guard withCamera,let camera = cameraDevice else { return }
                let settled = frames >= 10 && !camera.isAdjustingExposure && !camera.isAdjustingWhiteBalance
                if settled || Date().timeIntervalSince(deviceReady!) > 2.5 { return }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw RecorderError.message("Kamera oder Mikrofon ist nicht bereit. Wird das Gerät bereits von einer anderen App verwendet?")
    }
    private var cameraURL: URL?
    private var cameraFailure: Error?
    private var cameraDevice: AVCaptureDevice?
    private var cameraFrames = 0
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput { microphoneReady = true; microphonePower = microphoneLevel(connection) }
        else { cameraReady = true; cameraFrames += 1; latestCamera = sampleBuffer.imageBuffer; CameraFeed.shared.publish(sampleBuffer) }
        if !recording || paused { onPreview?(CapturePreviewSample(camera: latestCamera,level: microphonePower)) }
        guard recording else { return }
        if paused {
            if output is AVCaptureAudioDataOutput, let silent = silenced(sampleBuffer) { microphoneSink?.append(silent) }
            return
        }
        if output is AVCaptureAudioDataOutput { microphoneSink?.append(sampleBuffer); return }
        if cameraSink == nil, cameraFailure == nil, let url = cameraURL, let image = sampleBuffer.imageBuffer {
            do { cameraSink = try MovieSink(url: url, width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image), fps: 30, audio: false) }
            catch { cameraFailure = error }
        }
        _ = cameraSink?.appendVideo(sampleBuffer)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard recording else { return }
        if paused {
            if type == .audio, let silent = silenced(sampleBuffer) { screenSink?.appendAudio(silent) }
            return
        }
        if type == .audio { screenSink?.appendAudio(sampleBuffer); return }
        guard type == .screen, sampleBuffer.imageBuffer != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              screenSink?.appendVideo(sampleBuffer) != nil else { return }
        latestScreen = sampleBuffer.imageBuffer
    }
    private func samplePointer() {
        guard recording, let firstTime = screenSink?.firstTime else { return }
        let time = max(0,(CMClockGetTime(CMClockGetHostTimeClock())-firstTime).seconds)
        if let window = source?.window, time-lastFrameRefresh > 0.15 {
            lastFrameRefresh = time
            if let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window.windowID) as? [[String:Any]])?.first,
               let dictionary = info[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) { bounds = rect }
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        let button = CGEventSource.buttonState(.combinedSessionState, button: .left) || CGEventSource.buttonState(.combinedSessionState, button: .right)
        if paused {
            // Keep the self-view and meter alive, but record nothing.
            onPreview?(CapturePreviewSample(camera: latestCamera,level: microphonePower)); lastButton = button; return
        }
        appendPointer(time: time,location: location,clicked: !clicksViaEvents && button && !lastButton)
        checkpointAndWatch(time: time,firstTime: firstTime)
        if let latestScreen,let last = samples.last {
            loomSink?.append(screen: latestScreen,camera: latestCamera,pointer: last.visible ? last.position : nil,time: CMClockGetTime(CMClockGetHostTimeClock()),start: firstTime)
            onPreview?(CapturePreviewSample(screen: latestScreen,camera: latestCamera,pointer: last.visible ? last.position : nil,level: microphonePower))
        }
        lastButton = button
    }
    /// Every few seconds: journal the take for crash recovery. Every tick: surface writer failures at once.
    private func checkpointAndWatch(time: Double,firstTime: CMTime) {
        if let journal, time-lastCheckpoint >= 3 {
            lastCheckpoint = time
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let cuts = pauses.isEmpty ? nil : Project.retainedCuts(duration: time,pauses: pauses.map { (($0.start-firstTime).seconds,(($0.end ?? now)-firstTime).seconds) })
            journal.checkpoint(width: dimensions.0,height: dimensions.1,fps: fps,duration: time,samples: samples[...],cuts: cuts,
                               hasCamera: cameraSink != nil,hasMicrophone: microphoneSink != nil,
                               cameraOffset: cameraSink?.firstTime.map { ($0-firstTime).seconds },microphoneOffset: microphoneSink?.firstTime.map { ($0-firstTime).seconds })
        }
        if let failure = screenSink?.failure, reportedProblems.insert("screen").inserted {
            onUnexpectedStop?("Bildschirmspur konnte nicht geschrieben werden: \(failure.localizedDescription)")
        }
        if cameraSink?.failure != nil || cameraFailure != nil, reportedProblems.insert("camera").inserted {
            onTrackProblem?("Kamera ausgefallen – der Bildschirm wird weiter aufgenommen.")
        }
        if microphoneSink?.failure != nil, reportedProblems.insert("microphone").inserted {
            onTrackProblem?("Mikrofon ausgefallen – der Bildschirm wird weiter aufgenommen.")
        }
    }
    private func appendPointer(time: Double,location: CGPoint,clicked: Bool) {
        let fit = min(Double(dimensions.0)/max(1,bounds.width),Double(dimensions.1)/max(1,bounds.height))
        let offsetX = (Double(dimensions.0)-bounds.width*fit)/2
        let offsetY = (Double(dimensions.1)-bounds.height*fit)/2
        let point = Point(((location.x-bounds.minX)*fit+offsetX)/Double(dimensions.0), ((location.y-bounds.minY)*fit+offsetY)/Double(dimensions.1))
        samples.append(PointerSample(time: max(0,time), position: point.clamped(), clicked: clicked, visible: bounds.contains(location)))
    }
    @MainActor private func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown]) { [weak self] event in
            guard let self,let location = event.cgEvent?.location else { return }
            let hostTime = event.timestamp, right = event.type == .rightMouseDown
            self.queue.async {
                guard self.recording,!self.paused,let firstTime = self.screenSink?.firstTime else { return }
                self.appendPointer(time: max(0,hostTime-firstTime.seconds),location: location,clicked: true)
                self.onClick?(location,max(0,hostTime-firstTime.seconds),right)
            }
        }
        clicksViaEvents = clickMonitor != nil
    }
    @MainActor private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.streamFailure = error }
        onUnexpectedStop?(error.localizedDescription)
    }
    func pause() async {
        await withCheckedContinuation { continuation in queue.async {
            if self.recording, !self.paused { self.paused = true; self.pauses.append((CMClockGetTime(CMClockGetHostTimeClock()),nil)) }
            continuation.resume()
        } }
    }
    func resume() async {
        await withCheckedContinuation { continuation in queue.async {
            if self.paused, let last = self.pauses.indices.last { self.paused = false; self.pauses[last].end = CMClockGetTime(CMClockGetHostTimeClock()) }
            continuation.resume()
        } }
    }
    func stop(name: String) async throws -> Project {
        let endTime = CMClockGetTime(CMClockGetHostTimeClock())
        var stopError: Error?
        do { try await stream?.stopCapture() } catch { stopError = error }
        stream = nil
        await removeClickMonitor()
        let pauseRanges: [(start: CMTime,end: CMTime?)] = await withCheckedContinuation { continuation in queue.async {
            self.recording = false; self.paused = false; self.pointerTimer?.cancel(); self.pointerTimer = nil; self.session?.stopRunning()
            continuation.resume(returning: self.pauses)
        } }
        guard let sink = screenSink else { throw RecorderError.message("Keine aktive Aufnahme.") }
        try await sink.finish(at: endTime)
        // From here the screen is safe on disk. Camera and microphone are finished independently: a failing extra
        // track is dropped with a warning instead of making the whole take unopenable.
        var problems: [String] = []
        var cameraSaved = false, microphoneSaved = false
        if let cameraSink {
            do { try await cameraSink.finish(at: endTime); cameraSaved = cameraFailure == nil }
            catch { problems.append("Kameraspur nicht gesichert (\(error.localizedDescription))") }
        } else if wantsCamera { problems.append("Kamera lieferte keine Bilder") }
        if let cameraFailure, cameraSink == nil || !cameraSaved { problems.append("Kamera: \(cameraFailure.localizedDescription)") }
        if let microphoneSink {
            do { try await microphoneSink.finish(); microphoneSaved = true }
            catch { problems.append("Mikrofonspur nicht gesichert (\(error.localizedDescription))") }
        }
        if !cameraSaved, let cameraURL { try? FileManager.default.removeItem(at: cameraURL) }
        if !microphoneSaved, microphoneSink != nil, let directory = journalDirectory {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("microphone.m4a"))
        }
        if !problems.isEmpty { warning = ([warning].compactMap { $0 }+["Gespeichert ohne ausgefallene Spuren: "+problems.joined(separator: "; ")]).joined(separator: " · ") }
        if let loomSink {
            // The fast Loom movie has no cuts; with pauses the regular export applies them.
            do { try await loomSink.finish(at: endTime); quickShareReady = pauseRanges.isEmpty }
            catch {
                loomSink.cancel()
                warning = "Schnell-Export nicht verfügbar; die gesicherten Originalspuren werden regulär exportiert. \(error.localizedDescription)"
            }
        }
        if let error = streamFailure ?? stopError { warning = [warning,error.localizedDescription].compactMap { $0 }.joined(separator: " · ") }
        var project = Project(name: name, duration: sink.duration, width: dimensions.0, height: dimensions.1, fps: fps)
        if let first = sink.firstTime, !pauseRanges.isEmpty {
            project.cuts = Project.retainedCuts(duration: sink.duration,pauses: pauseRanges.map { ((($0.start-first).seconds),(($0.end ?? endTime)-first).seconds) })
        }
        project.pointer = samples.sorted { $0.time < $1.time }
        project.zooms = Motion.automaticZooms(pointer: project.pointer, duration: sink.duration)
        project.hasCamera = cameraSaved
        project.hasMicrophone = microphoneSaved
        if microphoneSaved, let micTime = microphoneSink?.firstTime, let screenTime = sink.firstTime { project.microphoneOffset = (micTime-screenTime).seconds }
        if cameraSaved, let cameraTime = cameraSink?.firstTime, let screenTime = sink.firstTime { project.cameraOffset = CMTimeGetSeconds(cameraTime-screenTime) }
        screenSink = nil; cameraSink = nil; microphoneSink = nil; loomSink = nil; latestScreen = nil; latestCamera = nil; session = nil; cameraFailure = nil; cameraDevice = nil; journal = nil
        return project
    }
    /// Stops capturing and discards everything written so far.
    func cancel() async { await abort() }
    private func abort() async {
        try? await stream?.stopCapture(); stream = nil
        await removeClickMonitor()
        await withCheckedContinuation { continuation in queue.async {
            self.recording = false; self.pointerTimer?.cancel(); self.pointerTimer = nil; self.session?.stopRunning()
            self.screenSink?.writer.cancelWriting(); self.cameraSink?.writer.cancelWriting(); self.microphoneSink?.writer.cancelWriting(); self.loomSink?.cancel()
            self.screenSink = nil; self.cameraSink = nil; self.microphoneSink = nil; self.loomSink = nil; self.latestScreen = nil; self.latestCamera = nil; self.session = nil; self.cameraFailure = nil
            continuation.resume()
        } }
    }
}
