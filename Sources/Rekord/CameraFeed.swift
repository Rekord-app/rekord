import AppKit
import SwiftUI
@preconcurrency import AVFoundation

/// Live camera frames for every on-screen self-view (camera bubble, floating controller, previews).
/// Frames come from the capture callbacks the app already receives and are shown with AVSampleBufferDisplayLayer,
/// so no preview layer ever attaches to (and reconfigures) a running capture session.
final class CameraFeed: @unchecked Sendable {
    static let shared = CameraFeed()
    private let lock = NSLock()
    private var layers: [ObjectIdentifier: Weak] = [:]
    private struct Weak { weak var layer: AVSampleBufferDisplayLayer? }
    func register(_ layer: AVSampleBufferDisplayLayer) { lock.lock(); layers[ObjectIdentifier(layer)] = Weak(layer: layer); lock.unlock() }
    func unregister(_ layer: AVSampleBufferDisplayLayer) { lock.lock(); layers[ObjectIdentifier(layer)] = nil; lock.unlock() }
    /// Called from capture queues with each camera frame.
    func publish(_ sample: CMSampleBuffer) {
        lock.lock(); let targets = layers.values.compactMap(\.layer); lock.unlock()
        guard !targets.isEmpty else { return }
        // A shallow copy carries the "display now" flag without touching the buffer that is also being recorded.
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(allocator: nil,sampleBuffer: sample,sampleBufferOut: &copy) == noErr, let copy,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(copy,createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments,0),to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary,Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        for layer in targets {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            if renderer.isReadyForMoreMediaData { renderer.enqueue(copy) }
        }
    }
}

/// Mirrored live camera, filled to its frame.
struct CameraFeedView: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraFeedNSView { CameraFeedNSView() }
    func updateNSView(_ view: CameraFeedNSView,context: Context) {}
}
final class CameraFeedNSView: NSView {
    let display = AVSampleBufferDisplayLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        display.videoGravity = .resizeAspectFill
        display.setAffineTransform(CGAffineTransform(scaleX: -1,y: 1))
        layer?.addSublayer(display)
        CameraFeed.shared.register(display)
    }
    required init?(coder: NSCoder) { nil }
    deinit { CameraFeed.shared.unregister(display) }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true); display.frame = bounds; CATransaction.commit()
    }
}
