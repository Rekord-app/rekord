import AppKit
import SwiftUI
import ScreenCaptureKit
import RecorderCore

/// On-screen source selection, one transparent window per display (never captured):
/// - Display: the display under the pointer gets an accent frame — that one is recorded.
/// - Window: the window under the pointer is highlighted; a click records it.
/// - Area: drag a rectangle (optionally locked to an aspect ratio) and record it.
@MainActor final class SelectionOverlayController {
    private var windows: [NSWindow] = []
    let model = SelectionModel()

    func select(_ mode: CaptureMode,store: EditorStore) {
        store.captureMode = mode
        model.hoveredWindow = nil
        if mode == .window, store.sources.first(where: { $0.id == store.selectedSource })?.window == nil { store.selectedSource = "" }
        if mode != .display { store.refreshSources() }
        update(store: store)
    }
    func update(store: EditorStore) {
        hide()
        guard store.hudActive else { return }
        let interactive = store.phase == .idle && store.countdown == nil && store.captureMode != .display
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame,styleMask: [.borderless],backing: .buffered,defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue-1)
            window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
            window.ignoresMouseEvents = !interactive
            window.sharingType = .none
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.contentView = NSHostingView(rootView: SelectionOverlayView(store: store,model: model,screen: ScreenInfo(screen)))
            window.setFrame(screen.frame,display: false)
            window.orderFrontRegardless()
            windows.append(window)
        }
        model.refreshWindowList()
    }
    func hide() { for window in windows { window.orderOut(nil) }; windows = [] }
    /// For live snapshots only.
    func makeCapturable() { for window in windows { window.sharingType = .readOnly } }
    var overlayWindows: [NSWindow] { windows }
}

struct ScreenInfo {
    let frame: CGRect           // Cocoa global coordinates (origin bottom-left)
    let displayID: CGDirectDisplayID
    let name: String
    init(_ screen: NSScreen) {
        frame = screen.frame
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        name = screen.localizedName
    }
    /// Converts a rectangle in global CG coordinates (origin top-left of the primary display) to this overlay's local top-left space.
    func local(fromGlobal rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let cocoaTop = primaryHeight-rect.minY
        return CGRect(x: rect.minX-frame.minX,y: frame.maxY-cocoaTop,width: rect.width,height: rect.height)
    }
}

struct WindowCandidate: Equatable {
    let id: CGWindowID
    let frame: CGRect           // global CG coordinates
    let app: String
    let title: String
}

@MainActor final class SelectionModel: ObservableObject {
    @Published var hoveredWindow: WindowCandidate?
    @Published var pointerScreen: CGDirectDisplayID?
    @Published var dragStart: CGPoint?
    @Published var dragRect: CGRect?
    @Published var aspect: Double? = 16.0/9.0
    private var candidates: [WindowCandidate] = []
    private var listed = Date.distantPast
    /// Front-to-back list of normal app windows (excluding this app), refreshed at most twice a second.
    func refreshWindowList() {
        listed = Date()
        let own = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String: Any]] ?? []
        candidates = info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) != own,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 100, rect.height > 80 else { return nil }
            return WindowCandidate(id: id,frame: rect,app: entry[kCGWindowOwnerName as String] as? String ?? "App",title: entry[kCGWindowName as String] as? String ?? "")
        }
    }
    func window(atGlobal point: CGPoint) -> WindowCandidate? {
        if Date().timeIntervalSince(listed) > 0.5 { refreshWindowList() }
        return candidates.first { $0.frame.contains(point) }
    }
}

private struct SelectionOverlayView: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var model: SelectionModel
    let screen: ScreenInfo
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                switch store.phase == .idle && store.countdown == nil ? store.captureMode : nil {
                case .display?: displayFrame(geometry.size)
                case .window?: windowPicker(geometry.size)
                case .area?: areaPicker(geometry.size)
                case nil: recordingOutline(geometry.size)
                }
            }.frame(width: geometry.size.width,height: geometry.size.height,alignment: .topLeading)
        }.ignoresSafeArea()
    }

    // MARK: Display

    @ViewBuilder private func displayFrame(_ size: CGSize) -> some View {
        SwiftUI.TimelineView(.periodic(from: .now,by: 0.2)) { _ in
            let active = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }.map { ScreenInfo($0).displayID } == screen.displayID
            ZStack {
                if active {
                    RoundedRectangle(cornerRadius: 12,style: .continuous).strokeBorder(Color.white.opacity(0.9),lineWidth: 3)
                        .shadow(color: .black.opacity(0.5),radius: 12)
                    label("\(screen.name) · ganzer Bildschirm",icon: "display").position(x: size.width/2,y: 64)
                }
            }.frame(width: size.width,height: size.height).animation(.easeOut(duration: 0.2),value: active)
        }
    }

    // MARK: Window

    private func windowPicker(_ size: CGSize) -> some View {
        let selected = store.sources.first { $0.id == store.selectedSource }?.window
        let highlight = model.hoveredWindow.map { screen.local(fromGlobal: $0.frame) }
        return ZStack(alignment: .topLeading) {
            dimmed(size,cutout: highlight)
            if let candidate = model.hoveredWindow, let rect = highlight {
                RoundedRectangle(cornerRadius: 10,style: .continuous).strokeBorder(Color.white.opacity(0.92),lineWidth: 3)
                    .frame(width: rect.width,height: rect.height).offset(x: rect.minX,y: rect.minY)
                    .shadow(color: .black.opacity(0.5),radius: 10)
                VStack(spacing: 6) {
                    label("\(candidate.app)\(candidate.title.isEmpty ? "" : " · \(candidate.title)")",icon: "macwindow")
                    Text("Klicken zum Aufnehmen · \(Int(rect.width))×\(Int(rect.height))").font(.system(size: 11,weight: .medium)).foregroundStyle(.white.opacity(0.85))
                }.position(x: rect.midX,y: rect.midY)
            } else if selected == nil {
                label("Fahre über ein Fenster und klicke es an",icon: "cursorarrow.click").position(x: size.width/2,y: 64)
            }
        }
        .frame(width: size.width,height: size.height,alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
                let global = CGPoint(x: screen.frame.minX+point.x,y: primaryHeight-(screen.frame.maxY-point.y))
                let next = model.window(atGlobal: global)
                if next != model.hoveredWindow { model.hoveredWindow = next }
            case .ended: break
            }
        }
        .onTapGesture {
            guard let candidate = model.hoveredWindow else { return }
            Task { await choose(candidate) }
        }
    }
    private func choose(_ candidate: WindowCandidate) async {
        if !store.sources.contains(where: { $0.id == "window-\(candidate.id)" }) {
            store.refreshSources()
            for _ in 0..<40 where store.sourcesLoading { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        guard store.sources.contains(where: { $0.id == "window-\(candidate.id)" }) else { store.status = "Dieses Fenster kann nicht aufgenommen werden."; return }
        store.selectedSource = "window-\(candidate.id)"
        store.startRecording()
    }

    // MARK: Area

    private func areaPicker(_ size: CGSize) -> some View {
        let current = model.dragRect ?? currentArea
        return ZStack(alignment: .topLeading) {
            dimmed(size,cutout: current)
            if let rect = current {
                Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 2,dash: [7,4])).foregroundStyle(.white)
                    .frame(width: rect.width,height: rect.height).offset(x: rect.minX,y: rect.minY)
                Text("\(Int(rect.width)) × \(Int(rect.height))").font(.system(size: 11,weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal,8).padding(.vertical,4).background(.black.opacity(0.6),in: Capsule())
                    .position(x: rect.midX,y: max(16,rect.minY-18))
                if model.dragRect == nil { areaBar(rect,size: size) }
            } else {
                label("Bereich aufziehen · Format oben wählen",icon: "rectangle.dashed").position(x: size.width/2,y: 64)
                aspectPicker.position(x: size.width/2,y: 112)
            }
        }
        .frame(width: size.width,height: size.height,alignment: .topLeading)
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
        .gesture(DragGesture(minimumDistance: 4,coordinateSpace: .local).onChanged { value in
            model.dragRect = constrained(from: value.startLocation,to: value.location,in: size)
        }.onEnded { value in
            let rect = constrained(from: value.startLocation,to: value.location,in: size)
            model.dragRect = nil
            guard rect.width >= 120, rect.height >= 80 else { return }
            setArea(rect)
        })
    }
    /// The area chosen on this screen, in local coordinates.
    private var currentArea: CGRect? {
        guard let area = store.areaSource, area.display?.displayID == screen.displayID else { return nil }
        return area.area
    }
    private func setArea(_ rect: CGRect) {
        guard let display = store.sources.first(where: { $0.display?.displayID == screen.displayID })?.display else { store.refreshSources(); return }
        store.areaSource = CaptureSource.area(rect,on: display)
    }
    private func constrained(from start: CGPoint,to end: CGPoint,in size: CGSize) -> CGRect {
        var w = abs(end.x-start.x), h = abs(end.y-start.y)
        if let aspect = model.aspect { if w/h > aspect { w = h*aspect } else { h = w/aspect } }
        let x = end.x >= start.x ? start.x : start.x-w, y = end.y >= start.y ? start.y : start.y-h
        return CGRect(x: max(0,x),y: max(0,y),width: min(w,size.width-max(0,x)),height: min(h,size.height-max(0,y))).integral
    }
    private func areaBar(_ rect: CGRect,size: CGSize) -> some View {
        HStack(spacing: 8) {
            aspectPicker
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1,height: 20)
            Button { if let area = store.areaSource?.area { setArea(fit(area,size: size)) } } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.plain).foregroundStyle(.white).help("Auf ganze Höhe vergrößern (Menüleiste bleibt draußen)")
            Button { store.prepareActiveSourceForStart(); store.startRecording() } label: {
                Label("Aufnehmen",systemImage: "record.circle").font(.system(size: 12,weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal,12).padding(.vertical,6).background(StudioTheme.accentGradient,in: Capsule())
            }.buttonStyle(.plain)
        }.padding(8).modifier(GlassPanel(cornerRadius: 16,tint: .black.opacity(0.4)))
            .environment(\.colorScheme,.dark)
            .position(x: min(max(rect.midX,200),size.width-200),y: min(rect.maxY+34,size.height-30))
    }
    /// Largest rectangle with the current aspect below the menu bar, centred.
    private func fit(_ rect: CGRect,size: CGSize) -> CGRect {
        let top = 37.0, available = CGSize(width: size.width,height: size.height-top)
        let aspect = model.aspect ?? rect.width/rect.height
        var w = available.width, h = w/aspect
        if h > available.height { h = available.height; w = h*aspect }
        return CGRect(x: (size.width-w)/2,y: top,width: w,height: h).integral
    }
    private var aspectPicker: some View {
        HStack(spacing: 2) {
            ForEach([("Frei",nil),("16:9",16.0/9.0),("9:16",9.0/16.0),("1:1",1.0),("4:5",4.0/5.0)] as [(String,Double?)],id: \.0) { title,value in
                Button {
                    model.aspect = value
                    if let area = store.areaSource?.area, let value { setArea(reshape(area,aspect: value)) }
                } label: {
                    Text(title).font(.system(size: 11,weight: .semibold)).foregroundStyle(.white.opacity(model.aspect == value ? 1 : 0.65))
                        .padding(.horizontal,9).padding(.vertical,5).background(model.aspect == value ? Color.white.opacity(0.2) : .clear,in: Capsule())
                }.buttonStyle(.plain)
            }
        }.padding(3).background(.black.opacity(0.45),in: Capsule())
    }
    private func reshape(_ rect: CGRect,aspect: Double) -> CGRect {
        var w = rect.width, h = w/aspect
        if h > screen.frame.height-rect.minY { h = screen.frame.height-rect.minY; w = h*aspect }
        return CGRect(x: rect.minX,y: rect.minY,width: min(w,screen.frame.width-rect.minX),height: h).integral
    }

    // MARK: While recording

    @ViewBuilder private func recordingOutline(_ size: CGSize) -> some View {
        if store.phase == .recording || store.countdown != nil, store.captureMode == .area, let rect = currentArea {
            Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 2,dash: [6,4])).foregroundStyle(StudioTheme.accent.opacity(0.9))
                .frame(width: rect.width+6,height: rect.height+6).offset(x: rect.minX-3,y: rect.minY-3)
        }
    }

    // MARK: Pieces

    private func dimmed(_ size: CGSize,cutout: CGRect?) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero,size: size))
            if let cutout { path.addRoundedRect(in: cutout,cornerSize: CGSize(width: 10,height: 10)) }
        }.fill(Color.black.opacity(0.32),style: FillStyle(eoFill: true)).allowsHitTesting(false)
    }
    private func label(_ text: String,icon: String) -> some View {
        Label(text,systemImage: icon).font(.system(size: 13,weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal,14).padding(.vertical,8).modifier(GlassPanel(cornerRadius: 18,tint: .black.opacity(0.35)))
            .environment(\.colorScheme,.dark)
    }
}
