import SwiftUI
import AppKit
@preconcurrency import AVFoundation

@MainActor final class RecordingPanelController {
    private var panel: NSPanel?
    func show(store: EditorStore) {
        if panel == nil {
            let height: CGFloat = store.withCamera ? 282 : 112
            let next = NSPanel(contentRect: CGRect(x: 0,y: 0,width: 240,height: height),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
            next.title = "Aufnahme-Controller"; next.setAccessibilityLabel("Aufnahme-Controller")
            next.isReleasedWhenClosed = false; next.isOpaque = false; next.backgroundColor = .clear
            next.level = .floating; next.hidesOnDeactivate = false; next.hasShadow = true
            next.isMovableByWindowBackground = true
            next.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            next.sharingType = .none
            next.contentView = NSHostingView(rootView: RecordingControllerView(store: store,monitor: store.monitor))
            let area = NSScreen.main?.visibleFrame ?? CGRect(x: 0,y: 0,width: 1440,height: 900)
            next.setFrameOrigin(CGPoint(x: area.minX+24,y: area.minY+24))
            panel = next
        }
        panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil); panel = nil }
}

struct RecordingControllerView: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var monitor: CaptureMonitor
    var body: some View {
        VStack(spacing: 12) {
            if store.withCamera {
                CameraImage(image: monitor.camera,session: monitor.cameraSession,enabled: true)
                    .frame(height: 158).clipShape(RoundedRectangle(cornerRadius: 14,style: .continuous))
            }
            HStack(spacing: 8) {
                Circle().fill(store.paused ? StudioTheme.warning : StudioTheme.accent).frame(width: 7,height: 7)
                    .shadow(color: (store.paused ? StudioTheme.warning : StudioTheme.accent).opacity(0.8),radius: 4)
                Text(store.phase == .preparing ? "Startet …" : (store.paused ? "Pause" : recordingClock(store.elapsed))).font(.system(size: 21,weight: .semibold,design: .rounded)).monospacedDigit().foregroundStyle(.white)
                    .accessibilityLabel(store.phase == .preparing ? "Aufnahme startet" : "Aufnahmedauer \(recordingClock(store.elapsed))")
                Spacer()
                if store.withMicrophone { AudioMeter(level: monitor.level).frame(width: 40,height: 16) }
            }
            HStack(spacing: 8) {
                Button { store.togglePause() } label: {
                    Image(systemName: store.paused ? "play.fill" : "pause.fill").font(.system(size: 14,weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44,height: 38).background(Color.white.opacity(0.14),in: Capsule())
                }.buttonStyle(.plain).disabled(store.phase != .recording)
                    .help(store.paused ? "Aufnahme fortsetzen · ⌘⇧P" : "Aufnahme pausieren · ⌘⇧P")
                    .accessibilityLabel(store.paused ? "Aufnahme fortsetzen" : "Aufnahme pausieren")
                Button { store.stopRecording() } label: {
                    HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 10,height: 10); Text("Stoppen") }
                        .font(.system(size: 14,weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 38).background(StudioTheme.accentGradient,in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel("Aufnahme stoppen")
            }
        }.padding(14).modifier(GlassPanel(cornerRadius: 24,tint: .black.opacity(0.45)))
            .environment(\.colorScheme,.dark)
    }
}

struct CameraImage: View {
    let image: CGImage?
    var session: AVCaptureSession? = nil
    let enabled: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.3)
                if enabled, session != nil || image != nil {
                    // Last composed still underneath (shows instantly), live frames on top.
                    if let image {
                        Image(decorative: image,scale: 1).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width,height: geometry.size.height).clipped().scaleEffect(x: -1,y: 1)
                    }
                    CameraFeedView().frame(width: geometry.size.width,height: geometry.size.height)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: enabled ? "video" : "video.slash").font(.title2)
                        Text(enabled ? "Kamera startet …" : "Kamera aus").font(.caption)
                    }.foregroundStyle(.secondary)
                }
            }
        }.accessibilityLabel(enabled ? "Live-Kameravorschau, gespiegelt" : "Kamera ausgeschaltet")
    }
}

struct AudioMeter: View {
    let level: Double
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<12) { index in
                    Capsule().fill(Double(index)/12 < level ? (index > 9 ? StudioTheme.warning : StudioTheme.success) : Color.white.opacity(0.10))
                }
            }.frame(width: geometry.size.width,height: geometry.size.height)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Mikrofonpegel").accessibilityValue("\(Int(level*100)) Prozent")
    }
}

func recordingClock(_ time: Double) -> String {
    let seconds = Int(max(0,time.isFinite ? time : 0))
    return seconds >= 3600 ? String(format:"%02d:%02d:%02d",seconds/3600,seconds/60%60,seconds%60) : String(format:"%02d:%02d",seconds/60,seconds%60)
}
