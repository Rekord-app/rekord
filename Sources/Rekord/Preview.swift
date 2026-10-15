import Foundation
@preconcurrency import AVFoundation
import RecorderCore
import AppKit
import SwiftUI

/// Native playback surface: AVPlayerLayer shows the composed editor video at display refresh.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerView { let view = PlayerLayerView(); view.playerLayer.player = player; return view }
    func updateNSView(_ view: PlayerLayerView,context: Context) { if view.playerLayer.player !== player { view.playerLayer.player = player } }
}
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Videovorschau")
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); playerLayer.frame = bounds; CATransaction.commit() }
}

/// Stills from the original recording for removed ranges, where the edited composition has no frame.

actor PreviewEngine {
    private var directory: URL?
    private var screen: AVAssetImageGenerator?
    private var camera: AVAssetImageGenerator?
    private var renderer: FrameRenderer?
    func frame(project: Project, directory: URL, time: Double) async throws -> CGImage? {
        if self.directory != directory {
            self.directory = directory
            renderer = nil
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: directory.appendingPathComponent("screen.mov")))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1600,height: 1600)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            screen = generator; camera = nil
            if project.hasCamera {
                let cam = AVAssetImageGenerator(asset: AVURLAsset(url: directory.appendingPathComponent("camera.mov")))
                cam.appliesPreferredTrackTransform = true; cam.maximumSize = CGSize(width: 720,height: 720)
                camera = cam
            }
        }
        guard let screen else { return nil }
        let t = min(max(0,time),max(0,project.duration-1/Double(project.fps)))
        let source = try await screen.image(at: CMTime(seconds: t,preferredTimescale: 600)).image
        var cameraImage: CGImage?
        if let camera, project.style.showCamera, t >= project.cameraOffset {
            cameraImage = try? await camera.image(at: CMTime(seconds: t-project.cameraOffset,preferredTimescale: 600)).image
        }
        if renderer == nil || renderer?.project.style != project.style || renderer?.project.zooms != project.zooms || renderer?.project.pointer.count != project.pointer.count { renderer = FrameRenderer(project: project,backgroundImage: try BackgroundAsset.load(project: project,directory: directory)) }
        let size = project.style.format.dimensions(height: 720)
        return renderer?.image(screen: source,camera: cameraImage,time: t,width: size.0,height: size.1)
    }
}
