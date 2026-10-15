import AppKit
import SwiftUI
import RecorderCore

/// The floating recorder: a glass toolbar at the bottom of the screen (like the system's ⌘⇧5 bar), a draggable
/// camera bubble, and the on-screen source selection. All of it belongs to this app and is never captured.
@MainActor final class RecorderHUDController {
    private unowned let store: EditorStore
    private var toolbar: NSPanel?
    private var bubble: NSPanel?
    let overlays = SelectionOverlayController()
    init(store: EditorStore) { self.store = store }

    func open() {
        let screen = activeScreen()
        if toolbar == nil {
            let size = CGSize(width: 1040,height: 92)
            let panel = HUDPanel(contentRect: CGRect(origin: .zero,size: size))
            panel.contentView = NSHostingView(rootView: RecorderToolbar(store: store,monitor: store.monitor,hud: self).frame(width: size.width,height: size.height))
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX-size.width/2,y: screen.visibleFrame.minY+18))
            toolbar = panel
        }
        if bubble == nil {
            let side = CameraBubbleSize.current.side
            let panel = HUDPanel(contentRect: CGRect(x: 0,y: 0,width: CameraBubbleSize.large.side+24,height: CameraBubbleSize.large.side+24))
            panel.isMovableByWindowBackground = true
            panel.contentView = NSHostingView(rootView: CameraBubbleView(store: store,monitor: store.monitor))
            // The panel is sized for the largest bubble; the bubble sits in its bottom-right corner.
            let frameSize = panel.frame.size
            let saved = UserDefaults.standard.string(forKey: "cameraBubbleOrigin").map(NSPointFromString)
            let origin = saved.flatMap { point in NSScreen.screens.contains { $0.visibleFrame.contains(CGRect(origin: point,size: frameSize).insetBy(dx: frameSize.width/2-side/2,dy: 20)) } ? point : nil }
                ?? CGPoint(x: screen.visibleFrame.maxX-frameSize.width-20,y: screen.visibleFrame.minY+120)
            panel.setFrameOrigin(origin)
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,object: panel,queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                UserDefaults.standard.set(NSStringFromPoint(window.frame.origin),forKey: "cameraBubbleOrigin")
            }
            bubble = panel
        }
        toolbar?.orderFrontRegardless(); bubble?.orderFrontRegardless()
        overlays.update(store: store)
    }
    func close() {
        overlays.hide()
        toolbar?.orderOut(nil); bubble?.orderOut(nil); toolbar = nil; bubble = nil
    }
    /// For live snapshots only: allow capturing the floating windows.
    func makeCapturable() { for panel in [toolbar,bubble].compactMap({ $0 }) { panel.sharingType = .readOnly } }
    var windows: [NSWindow] { [toolbar,bubble].compactMap { $0 } }
    private func activeScreen() -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// Borderless, non-activating floating panel that keeps working over other apps and full-screen spaces.
final class HUDPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .floating; hidesOnDeactivate = false; isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        sharingType = .none
    }
    override var canBecomeKey: Bool { true }
}

enum CameraBubbleSize: String, CaseIterable {
    case small, medium, large
    var side: CGFloat { switch self { case .small: return 132; case .medium: return 188; case .large: return 260 } }
    static var current: CameraBubbleSize {
        get { CameraBubbleSize(rawValue: UserDefaults.standard.string(forKey: "cameraBubbleSize") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue,forKey: "cameraBubbleSize") }
    }
}

/// Your camera on screen while you set up and record (mirrored like a mirror). Drag to move; hover for size.
struct CameraBubbleView: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var monitor: CaptureMonitor
    @State private var size = CameraBubbleSize.current
    @State private var hovering = false
    var body: some View {
        let side = size.side
        let shape = CameraShapeOutline(shape: store.recordingStyle.cameraShape ?? (store.recordingMode == .loom ? .circle : .rounded))
        ZStack {
            if store.withCamera {
                CameraImage(image: monitor.camera,session: monitor.cameraSession,enabled: true)
                    .frame(width: side,height: side)
                    .clipShape(shape)
                    .overlay(shape.stroke(Color.white.opacity(0.18),lineWidth: 1))
                    .shadow(color: .black.opacity(0.4),radius: 18,y: 8)
                    .overlay(alignment: .bottom) {
                        if hovering {
                            HStack(spacing: 4) {
                                ForEach(CameraBubbleSize.allCases,id: \.self) { option in
                                    Button { withAnimation(.snappy(duration: 0.25)) { size = option; CameraBubbleSize.current = option } } label: {
                                        Circle().fill(option == size ? Color.white : Color.white.opacity(0.35)).frame(width: [6,8,10][CameraBubbleSize.allCases.firstIndex(of: option)!],height: [6,8,10][CameraBubbleSize.allCases.firstIndex(of: option)!])
                                            .frame(width: 18,height: 18).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help(["Klein","Mittel","Groß"][CameraBubbleSize.allCases.firstIndex(of: option)!])
                                }
                            }.padding(.horizontal,8).padding(.vertical,3).background(.black.opacity(0.45),in: Capsule()).padding(.bottom,10)
                                .transition(.opacity)
                        }
                    }
                    .onHover { hover in withAnimation(.easeOut(duration: 0.15)) { hovering = hover } }
                    .animation(.snappy(duration: 0.3),value: store.recordingMode)
            }
        }
        .frame(width: CameraBubbleSize.large.side+24,height: CameraBubbleSize.large.side+24,alignment: .bottomTrailing)
        .accessibilityLabel("Deine Kamera, verschiebbar")
    }
}

/// The glass bar: close, mode, source type, devices, settings and record — or, while recording, the recording pill.
struct RecorderToolbar: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var monitor: CaptureMonitor
    let hud: RecorderHUDController
    var body: some View {
        Group {
            if store.phase == .recording || store.phase == .stopping { recordingPill }
            else { setupBar }
        }
        .environment(\.colorScheme,.dark)
        .frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .bottom)
        .animation(.snappy(duration: 0.3),value: store.phase == .recording)
    }

    private var setupBar: some View {
        HStack(spacing: 10) {
            Button { store.closeRecorder() } label: { Image(systemName: "xmark").font(.system(size: 12,weight: .bold)).foregroundStyle(.white.opacity(0.85)).frame(width: 30,height: 30).background(Color.white.opacity(0.1),in: Circle()) }
                .buttonStyle(.plain).help("Schließen · Esc").accessibilityLabel("Recorder schließen").keyboardShortcut(.cancelAction).disabled(store.countdown != nil)
            divider
            modeMenu
            divider
            HStack(spacing: 4) {
                sourceButton(.display,title: "Bildschirm",icon: "display")
                sourceButton(.window,title: "Fenster",icon: "macwindow")
                sourceButton(.area,title: "Bereich",icon: "rectangle.dashed")
            }
            divider
            DeviceChip(title: "Kamera",icon: "video.fill",offIcon: "video.slash",isOn: $store.withCamera,devices: store.cameras,selection: $store.cameraID,defaultName: store.defaultCameraName,level: nil) { store.devicesChanged() }
            DeviceChip(title: "Mikrofon",icon: "mic.fill",offIcon: "mic.slash",isOn: $store.withMicrophone,devices: store.microphones,selection: $store.microphoneID,defaultName: store.defaultMicrophoneName,level: monitor.level) { store.devicesChanged() }
            SimpleChip(title: "Ton",icon: "speaker.wave.2.fill",offIcon: "speaker.slash",isOn: $store.withAudio)
            settingsMenu
            divider
            startButton
        }
        .padding(.horizontal,12).padding(.vertical,10)
        .modifier(GlassPanel(cornerRadius: 26,tint: .black.opacity(0.38)))
        .environmentObject(store)
        .fixedSize()
        .onChange(of: store.withCamera) { store.updateMonitor() }
        .onChange(of: store.withMicrophone) { store.updateMonitor() }
    }
    private var divider: some View { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1,height: 26) }
    private var modeMenu: some View {
        Menu {
            Picker("Modus",selection: Binding(get: { store.recordingMode },set: { store.chooseMode($0) })) {
                Label("Studio · danach gestalten",systemImage: "sparkles.rectangle.stack").tag(RecordingMode.studio)
                Label("Loom · sofort teilen",systemImage: "link").tag(RecordingMode.loom)
            }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: store.recordingMode == .studio ? "sparkles.rectangle.stack" : "link")
                Text(store.recordingMode == .studio ? "Studio" : "Loom").font(.system(size: 12,weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8,weight: .bold)).foregroundStyle(.secondary)
            }.foregroundStyle(.white).padding(.horizontal,10).padding(.vertical,7).contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(store.countdown != nil)
    }
    private func sourceButton(_ mode: CaptureMode,title: String,icon: String) -> some View {
        let selected = store.captureMode == mode
        return Button { withAnimation(.snappy(duration: 0.2)) { hud.overlays.select(mode,store: store) } } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15,weight: .medium))
                Text(title).font(.system(size: 9.5,weight: .semibold))
            }.frame(width: 66,height: 44)
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.62))
            .background(selected ? Color.white.opacity(0.16) : .clear,in: RoundedRectangle(cornerRadius: 11,style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).disabled(store.countdown != nil).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private var settingsMenu: some View {
        Menu {
            Picker("Bildrate",selection: $store.captureFPS) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
            if store.recordingMode == .studio {
                Picker("Videoformat",selection: $store.recordingStyle.format) { ForEach(CanvasFormat.allCases,id: \.self) { Text($0.label).tag($0) } }
            }
            Toggle("Countdown vor dem Start",isOn: $store.countdownEnabled)
            Toggle("MacBook-Bildschirm auf 16:9 zuschneiden",isOn: $store.autoWidescreen)
            Divider()
            Button("Hauptfenster öffnen") { store.bringMainWindowForward() }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13,weight: .bold)).frame(width: 30,height: 30).foregroundStyle(.white.opacity(0.8)).contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Einstellungen").accessibilityLabel("Aufnahme-Einstellungen")
    }
    @ViewBuilder private var startButton: some View {
        if let count = store.countdown {
            Button { store.cancelCountdown() } label: {
                HStack(spacing: 8) { Text("\(count)").font(.system(size: 15,weight: .bold,design: .rounded)).monospacedDigit().contentTransition(.numericText(countsDown: true)); Text("Abbrechen").font(.system(size: 12,weight: .semibold)) }
                    .foregroundStyle(.white).padding(.horizontal,16).frame(height: 40).background(Color.white.opacity(0.14),in: Capsule())
            }.buttonStyle(.plain)
        } else if store.phase == .preparing {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Startet …").font(.system(size: 12)) }.padding(.horizontal,14).frame(height: 40)
        } else {
            Button { store.prepareActiveSourceForStart(); store.startRecording() } label: {
                HStack(spacing: 8) { RecordDot(); Text(startTitle).lineLimit(1) }
            }.buttonStyle(AccentButtonStyle(height: 40)).keyboardShortcut(.defaultAction).disabled(!canStart).opacity(canStart ? 1 : 0.45)
                .help(canStart ? "Aufnahme starten · ⌘⇧1" : startHint)
        }
    }
    private var canStart: Bool {
        guard !store.sourcesLoading else { return false }
        switch store.captureMode {
        case .display: return store.sources.contains { $0.display != nil }
        case .window: return store.sources.first { $0.id == store.selectedSource }?.window != nil
        case .area: return store.areaSource != nil
        }
    }
    private var startTitle: String {
        switch store.captureMode {
        case .display: return "Aufnehmen"
        case .window: return canStart ? "Fenster aufnehmen" : "Fenster wählen"
        case .area: return canStart ? "Bereich aufnehmen" : "Bereich ziehen"
        }
    }
    private var startHint: String { store.captureMode == .window ? "Klicke auf das Fenster, das du aufnehmen willst." : "Ziehe auf dem Bildschirm einen Bereich auf." }

    // MARK: Recording pill

    private var recordingPill: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(store.paused ? StudioTheme.warning : StudioTheme.accent).frame(width: 9,height: 9)
                    .shadow(color: (store.paused ? StudioTheme.warning : StudioTheme.accent).opacity(0.8),radius: 4)
                    .opacity(store.paused ? 1 : 0.95)
                Text(store.phase == .stopping ? "Speichert …" : recordingClock(store.elapsed)).font(.system(size: 15,weight: .semibold,design: .rounded)).monospacedDigit().foregroundStyle(.white)
                    .frame(minWidth: 52,alignment: .leading)
            }.padding(.leading,6)
            if store.withMicrophone { LevelBars(level: monitor.level).frame(width: 18,height: 14) }
            if let problem = store.trackProblem {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(StudioTheme.warning).help(problem)
                    .accessibilityLabel(problem)
            }
            divider
            pillButton(store.paused ? "play.fill" : "pause.fill",help: store.paused ? "Fortsetzen · ⌘⇧P" : "Pausieren · ⌘⇧P") { store.togglePause() }
            pillButton("arrow.counterclockwise",help: "Neu starten (diese Aufnahme verwerfen)") { store.restartRecording() }
            pillButton("trash",help: "Verwerfen") { store.discardRecording() }
            Button { store.stopRecording() } label: {
                HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 11,height: 11); Text("Stopp") }
            }.buttonStyle(AccentButtonStyle(height: 36)).help("Aufnahme beenden · ⌘⇧2").accessibilityLabel("Aufnahme stoppen").disabled(store.phase != .recording)
        }
        .padding(.horizontal,10).padding(.vertical,8)
        .modifier(GlassPanel(cornerRadius: 26,tint: .black.opacity(0.45)))
        .fixedSize()
        .disabled(store.phase != .recording)
    }
    private func pillButton(_ icon: String,help: String,action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13,weight: .semibold)).foregroundStyle(.white).frame(width: 34,height: 34).background(Color.white.opacity(0.12),in: Circle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}
