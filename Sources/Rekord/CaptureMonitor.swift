import AppKit
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreImage
import RecorderCore

// Preview frames never enter a movie writer. One bounded worker keeps UI work off the media queue.
struct CapturePreviewSample: @unchecked Sendable {
    var image: CGImage?
    var screen: CVPixelBuffer?
    var camera: CVPixelBuffer?
    var pointer: Point?
    var level: Double?
}

final class LiveCompositionWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.sapunov.rekord.live-preview",qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastSubmit = 0.0
    private var latest = CapturePreviewSample()
    private let ci = CIContext(options: [.cacheIntermediates:false])
    private var screen: CGImage?
    private var camera: CGImage?
    private var level = 0.0
    private let mode: RecordingMode
    private let style: Style
    private let plain: Bool
    /// `plain` shows only screen and camera at the source's aspect ratio: no background, margin, corners or
    /// shadow. Setup and recording previews use it; the project's look is applied in the editor.
    init(mode: RecordingMode,style: Style,plain: Bool = false) {
        self.mode = mode; self.plain = plain
        var style = style
        if plain { style.padding = 0; style.cornerRadius = 0; style.shadow = 0 }
        self.style = style
    }
    func submit(_ sample: CapturePreviewSample,receive: @escaping @Sendable (CGImage?,CGImage?,Double) -> Void) {
        lock.lock()
        if let image = sample.image { latest.image = image; latest.screen = nil; latest.pointer = sample.pointer }
        if let screen = sample.screen { latest.screen = screen; latest.image = nil; latest.pointer = sample.pointer }
        if let camera = sample.camera { latest.camera = camera }
        if let level = sample.level { latest.level = level }
        let now = ProcessInfo.processInfo.systemUptime
        guard !busy else { lock.unlock(); return }
        let delay = max(0,1.0/15-(now-lastSubmit))
        busy = true; lastSubmit = now+delay; lock.unlock()
        queue.asyncAfter(deadline: .now()+delay) { [self] in
            lock.lock(); let sample = latest; lock.unlock()
            if let image = sample.image { screen = image }
            if let buffer = sample.screen { screen = image(buffer,maxEdge: 1280) }
            if let buffer = sample.camera { camera = image(buffer,maxEdge: 480) }
            if let value = sample.level { level = value }
            var composed: CGImage?
            if let screen {
                var project = Project(name: "Live",duration: 1,width: screen.width,height: screen.height)
                project.mode = mode; project.style = style
                if let point = sample.pointer { project.pointer = [PointerSample(time: 0,position: point)] }
                let fit = min(960.0/Double(screen.width),960.0/Double(screen.height))
                let size = plain ? (max(2,Int(Double(screen.width)*fit)/2*2),max(2,Int(Double(screen.height)*fit)/2*2)) : style.format.dimensions(height: 540)
                composed = FrameRenderer(project: project).image(screen: screen,camera: camera,time: 0,width: size.0,height: size.1)
            }
            lock.lock(); busy = false; lock.unlock()
            receive(composed,camera,level)
        }
    }
    private func image(_ buffer: CVPixelBuffer,maxEdge: CGFloat) -> CGImage? {
        let source = CIImage(cvPixelBuffer: buffer)
        let scale = min(1,maxEdge/max(source.extent.width,source.extent.height))
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale,y: scale))
        return ci.createCGImage(scaled,from: scaled.extent)
    }
}

private final class PreviewDeviceSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let receive: @Sendable (CapturePreviewSample) -> Void
    private var camera: CVPixelBuffer?
    init(receive: @escaping @Sendable (CapturePreviewSample) -> Void) { self.receive = receive }
    func captureOutput(_ output: AVCaptureOutput,didOutput sampleBuffer: CMSampleBuffer,from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput { camera = sampleBuffer.imageBuffer; CameraFeed.shared.publish(sampleBuffer) }
        receive(CapturePreviewSample(camera: camera,level: output is AVCaptureAudioDataOutput ? microphoneLevel(connection) : nil))
    }
}

func microphoneLevel(_ connection: AVCaptureConnection) -> Double {
    let db = Double(connection.audioChannels.map(\.averagePowerLevel).max() ?? -80)
    return min(1,max(0,(db+60)/60))
}

private actor PreviewDevices {
    private var session: AVCaptureSession?
    private var sink: PreviewDeviceSink?
    private let queue = DispatchQueue(label: "dev.sapunov.rekord.device-preview")
    @discardableResult
    func start(camera: Bool,microphone: Bool,cameraID: String,microphoneID: String,receive: @escaping @Sendable (CapturePreviewSample) -> Void) throws -> AVCaptureSession? {
        guard camera || microphone else { return nil }
        let next = AVCaptureSession(); next.beginConfiguration()
        let sink = PreviewDeviceSink(receive: receive)
        if camera {
            guard let device = CaptureDevices.camera(id: cameraID) else { throw RecorderError.message("Keine Kamera verbunden.") }
            next.sessionPreset = .hd1280x720
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput(); output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(sink,queue: queue)
            guard next.canAddInput(input),next.canAddOutput(output) else { throw RecorderError.message("Kameravorschau nicht verfügbar.") }
            next.addInput(input); next.addOutput(output)
        }
        if microphone {
            guard let device = CaptureDevices.microphone(id: microphoneID) else { throw RecorderError.message("Kein Mikrofon verbunden.") }
            let input = try AVCaptureDeviceInput(device: device), output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(sink,queue: queue)
            guard next.canAddInput(input),next.canAddOutput(output) else { throw RecorderError.message("Mikrofonvorschau nicht verfügbar.") }
            next.addInput(input); next.addOutput(output)
        }
        next.commitConfiguration(); self.sink = sink; session = next; next.startRunning()
        return camera ? next : nil
    }
    func stop() { session?.stopRunning(); session = nil; sink = nil }
}

@MainActor final class CaptureMonitor: ObservableObject {
    @Published private(set) var frame: CGImage?
    @Published private(set) var camera: CGImage?
    @Published private(set) var level = 0.0
    @Published private(set) var message = "Wähle einen Bildschirm oder ein Fenster."
    @Published private(set) var renderedFrames = 0
    /// Running camera session for the native self-view: the setup preview session, then the recording session.
    @Published private(set) var cameraSession: AVCaptureSession?
    func showCamera(session: AVCaptureSession?) { cameraSession = session }
    private var generation = 0
    private var screenshots: Task<Void,Never>?
    private let devices = PreviewDevices()
    func receiver(mode: RecordingMode,style: Style) -> @Sendable (CapturePreviewSample) -> Void {
        generation += 1
        // The screen is composed here; the camera is shown as a native live layer on top (smooth, no extra copy).
        var screenOnly = style; screenOnly.showCamera = false
        let generation = generation, worker = LiveCompositionWorker(mode: mode,style: screenOnly,plain: true)
        return { [weak self] sample in
            worker.submit(sample) { [weak self] frame,camera,level in
                Task { @MainActor in
                    guard let self,self.generation == generation else { return }
                    self.frame = frame; self.camera = camera; self.level = level; self.renderedFrames += 1
                }
            }
        }
    }
    func start(source: CaptureSource?,camera: Bool,microphone: Bool,cameraID: String = "",microphoneID: String = "",mode: RecordingMode,style: Style) async throws {
        frame = nil; self.camera = nil; level = 0
        message = source == nil ? "Wähle einen Bildschirm oder ein Fenster." : "Live-Vorschau wird geladen …"
        let receive = receiver(mode: mode,style: style)
        if camera, !(await AVCaptureDevice.requestAccess(for: .video)) { throw RecorderError.message("Kamerazugriff fehlt. Bitte in den Systemeinstellungen freigeben.") }
        if microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) { throw RecorderError.message("Mikrofonzugriff fehlt. Bitte in den Systemeinstellungen freigeben.") }
        try Task.checkCancellation()
        cameraSession = try await devices.start(camera: camera,microphone: microphone,cameraID: cameraID,microphoneID: microphoneID,receive: receive)
        try Task.checkCancellation()
        guard let source else { return }
        let filter = try await ScreenRecorder.contentFilter(for: source)
        let config = SCStreamConfiguration(), size = source.area?.size ?? filter.contentRect.size
        let scale = min(Double(filter.pointPixelScale),1280.0/Double(max(1,max(size.width,size.height))))
        config.width = max(2,Int(size.width*scale)/2*2); config.height = max(2,Int(size.height*scale)/2*2)
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true; config.colorSpaceName = CGColorSpace.sRGB
        if let area = source.area { config.sourceRect = area }
        config.scalesToFit = true; config.preservesAspectRatio = true
        screenshots = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter,configuration: config)
                    try Task.checkCancellation()
                    receive(CapturePreviewSample(image: image))
                    self?.message = "Live-Vorschau"
                    try await Task.sleep(nanoseconds: 90_000_000)
                } catch is CancellationError { return }
                catch { self?.message = "Quelle nicht verfügbar. Bitte Quellen aktualisieren."; return }
            }
        }
    }
    func stop(clear: Bool = true) async {
        generation += 1; screenshots?.cancel(); screenshots = nil
        cameraSession = nil
        await devices.stop()
        if clear { frame = nil; camera = nil; level = 0 }
    }
    func showError(_ message: String) { self.message = message }
}
