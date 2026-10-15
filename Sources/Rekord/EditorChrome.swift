import SwiftUI
import AVFoundation
import RecorderCore

/// Editor top bar: back to recordings, editable title, format and crop, audience view, export and share.
struct EditorTopBar: View {
    @EnvironmentObject var store: EditorStore
    @Binding var audiencePresented: Bool
    @State private var title = ""
    var body: some View {
        HStack(spacing: 12) {
            Button { store.showRecordingSetup() } label: {
                HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 11,weight: .bold)); Text("Aufnahmen") }
            }.buttonStyle(PillButtonStyle(height: 30)).disabled(store.busy).help("Zurück zur Bibliothek")
            TextField("Titel",text: $title,onCommit: { store.rename(title) })
                .textFieldStyle(.plain).font(StudioFont.title).foregroundStyle(StudioTheme.text).frame(maxWidth: 360)
                .onAppear { title = store.displayName } .onChange(of: store.directory) { title = store.displayName }
                .accessibilityLabel("Titel des Videos")
            Spacer(minLength: 8)
            formatMenu
            cropMenu
            Menu {
                Button("Alle Edits entfernen (Zooms, Schnitte, Kamera-Layouts)") { store.removeAllEdits() }
                Button("Nur alle Zooms entfernen") { store.removeAllZooms() }
                if store.project?.cameraLayouts?.isEmpty == false { Button("Nur Kamera-Layouts entfernen") { store.removeAllCameraLayouts() } }
                Button("Nur Schnitte zurücksetzen") { store.resetCuts() }
                Divider()
                Button("Klick-Zooms neu erzeugen") { store.autoZoom() }
            } label: { menuLabel(icon: "wand.and.rays",text: "Edits") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Automatische Edits entfernen oder neu erzeugen · ⌘Z macht alles rückgängig").disabled(store.busy)
            Rectangle().fill(StudioTheme.hairlineStrong).frame(width: 1,height: 22)
            Button { audiencePresented = true } label: { Image(systemName: "play.rectangle") }
                .buttonStyle(IconButtonStyle(size: 30,filled: false)).help("Zuschaueransicht").accessibilityLabel("Zuschaueransicht").disabled(store.busy)
            Button { store.export() } label: { Label("Exportieren",systemImage: "square.and.arrow.up") }
                .buttonStyle(PillButtonStyle(height: 30,prominent: true)).disabled(store.project == nil)
            Menu {
                Button("Link teilen") { store.share() }
                Button("Als Video-Angebot teilen …") { store.share(forOffer: true) }
            } label: { Label("Teilen",systemImage: "link") }
                .buttonStyle(AccentButtonStyle(height: 30)).disabled(store.busy)
        }.padding(.horizontal,18).frame(height: 56)
        .background(StudioTheme.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioTheme.hairline).frame(height: 1) }
    }
    private var formatMenu: some View {
        Menu {
            Picker("Format",selection: Binding(get: { store.project?.style.format ?? .landscape },set: { value in store.edit { $0.style.format = value } })) {
                ForEach(CanvasFormat.allCases,id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.inline)
        } label: { menuLabel(icon: "aspectratio",text: store.project?.style.format.rawValue ?? "16:9") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Videoformat").disabled(store.busy)
    }
    private var cropMenu: some View {
        let project = store.project
        let current: CropRect.Preset = {
            guard let project, let crop = project.style.crop else { return .original }
            return crop.matchingPreset(sourceWidth: project.width,sourceHeight: project.height)
        }()
        let widescreenSource = project.map { abs(Double($0.width)/Double($0.height)-16.0/9.0) <= 0.01 } ?? true
        return Menu {
            Picker("Ausschnitt",selection: Binding(get: { current },set: { preset in store.edit { $0.style.crop = CropRect.preset(preset,sourceWidth: $0.width,sourceHeight: $0.height) } })) {
                Text("Ganze Aufnahme").tag(CropRect.Preset.original)
                Text("16:9 · ohne Menüleiste & Dock").tag(CropRect.Preset.widescreenWithoutMenuBar)
                Text("16:9 · mittig").tag(CropRect.Preset.widescreenCentered)
            }.pickerStyle(.inline)
        } label: { menuLabel(icon: "crop",text: current == .original ? "Ausschnitt" : "16:9") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(store.busy || widescreenSource).help(widescreenSource ? "Aufnahme ist bereits 16:9" : "Ausschnitt der Aufnahme")
    }
    private func menuLabel(icon: String,text: String) -> some View {
        HStack(spacing: 6) { Image(systemName: icon); Text(text); Image(systemName: "chevron.down").font(.system(size: 8,weight: .bold)).foregroundStyle(StudioTheme.textTertiary) }
            .font(StudioFont.control).foregroundStyle(StudioTheme.textSecondary).padding(.horizontal,10).frame(height: 30)
            .background(StudioTheme.fill,in: Capsule()).overlay(Capsule().strokeBorder(StudioTheme.hairline)).contentShape(Capsule())
    }
}

/// Transport between canvas and timeline: editing tools left, play controls and time centre.
struct TransportBar: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                tool("scissors","Schneiden · ⌘B") { store.split(); store.inspectorTab = .cut }
                tool("trash","Abschnitt entfernen · ⌫") { store.deleteCut() }.disabled((store.project?.cuts.count ?? 0) < 2 || store.selectedCut == nil)
                tool("plus.magnifyingglass","Zoom an der Abspielposition") { store.addZoom() }
                Spacer()
                if let p = store.project {
                    Text("\(p.zooms.count) Zoom\(p.zooms.count == 1 ? "" : "s") · \(p.cuts.count) Abschnitt\(p.cuts.count == 1 ? "" : "e")").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
                }
            }
            HStack(spacing: 14) {
                Button { store.seekEdited(0) } label: { Image(systemName: "backward.end.fill").font(.system(size: 12)) }.buttonStyle(.plain).foregroundStyle(StudioTheme.textSecondary).help("Zum Anfang").accessibilityLabel("Zum Anfang")
                Button { store.togglePlayback() } label: {
                    Image(systemName: store.playing ? "pause.fill" : "play.fill").font(.system(size: 14,weight: .bold)).foregroundStyle(.black)
                        .frame(width: 36,height: 36).background(Color.white,in: Circle()).offset(x: store.playing ? 0 : 1)
                        .shadow(color: .black.opacity(0.35),radius: 6,y: 2)
                }.buttonStyle(.plain).help("Abspielen / Pause · Leertaste").accessibilityLabel(store.playing ? "Pause" : "Abspielen")
                if let p = store.project {
                    HStack(spacing: 4) {
                        Text(clock(store.editedTime)).foregroundStyle(StudioTheme.text)
                        Text("/ \(clock(p.editedDuration))").foregroundStyle(StudioTheme.textTertiary)
                    }.font(.system(size: 12,weight: .medium,design: .rounded)).monospacedDigit().frame(width: 110,alignment: .leading)
                }
            }.padding(.leading,110)
        }.padding(.horizontal,18).frame(height: 50).disabled(store.project == nil || store.busy)
    }
    private func tool(_ icon: String,_ help: String,action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.buttonStyle(IconButtonStyle(size: 30)).help(help).accessibilityLabel(help)
    }
}

/// Thumbnails across the recording for the clip track.
@MainActor final class Filmstrip: ObservableObject {
    @Published private(set) var frames: [CGImage] = []
    private var loaded: URL?
    static let count = 36
    func load(directory: URL,duration: Double) async {
        guard loaded != directory else { return }
        loaded = directory; frames = []
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: directory.appendingPathComponent("screen.mov")))
        generator.maximumSize = CGSize(width: 220,height: 220); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5,preferredTimescale: 600); generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5,preferredTimescale: 600)
        var result: [CGImage] = []
        for i in 0..<Self.count {
            let t = duration*(Double(i)+0.5)/Double(Self.count)
            if let image = try? await generator.image(at: CMTime(seconds: t,preferredTimescale: 600)).image { result.append(image) }
            if Task.isCancelled || loaded != directory { return }
        }
        frames = result
    }
}

/// Source-time timeline: ruler with playhead, clip track (filmstrip, removed ranges hatched, trimmable edges)
/// and zoom track (drag to move, drag edges to resize). Drags preview locally and commit once on release.
struct EditorTimeline: View {
    @EnvironmentObject var store: EditorStore
    let project: Project
    @StateObject private var filmstrip = Filmstrip()
    @State private var cutDrag: (id: UUID,edge: Edge,value: Double)?
    @State private var zoomDrag: (id: UUID,start: Double,end: Double)?
    @State private var layoutDrag: (id: UUID,start: Double,end: Double)?
    enum Edge { case start, end }
    private let rulerHeight: CGFloat = 22, clipHeight: CGFloat = 54, zoomHeight: CGFloat = 32, layoutHeight: CGFloat = 24
    private var totalHeight: CGFloat { rulerHeight+clipHeight+zoomHeight+16+(project.hasCamera ? layoutHeight+8 : 0) }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, duration = max(0.01,project.duration)
            let x = { (t: Double) in CGFloat(t/duration)*width }
            let time = { (px: CGFloat) in min(duration,max(0,Double(px/width)*duration)) }
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading,spacing: 8) {
                    ruler(width: width,duration: duration).frame(height: rulerHeight)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { store.seekSource(time($0.location.x)) })
                    clipTrack(width: width,x: x,time: time).frame(height: clipHeight)
                    zoomTrack(width: width,x: x,time: time).frame(height: zoomHeight)
                    if project.hasCamera { layoutTrack(width: width,x: x,time: time).frame(height: layoutHeight) }
                }
                playhead(x: x(store.sourceTime))
            }
        }
        .frame(height: totalHeight)
        .task(id: store.directory) { if let directory = store.directory { await filmstrip.load(directory: directory,duration: project.duration) } }
    }

    // MARK: Ruler & playhead

    private func ruler(width: CGFloat,duration: Double) -> some View {
        let step = [0.5,1,2,5,10,15,30,60,120,300].first { duration/$0 <= 12 } ?? 600
        let ticks = Array(stride(from: 0.0,through: duration,by: step))
        return ZStack(alignment: .topLeading) {
            ForEach(ticks,id: \.self) { t in
                VStack(alignment: .leading,spacing: 2) {
                    Rectangle().fill(StudioTheme.hairlineStrong).frame(width: 1,height: 6)
                    Text(rulerLabel(t)).font(.system(size: 9,weight: .medium)).monospacedDigit().foregroundStyle(StudioTheme.textTertiary).fixedSize()
                }.offset(x: CGFloat(t/duration)*width)
            }
        }.frame(width: width,alignment: .topLeading)
    }
    private func rulerLabel(_ t: Double) -> String { t >= 60 ? String(format: "%d:%02d",Int(t)/60,Int(t)%60) : (t.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(t))s" : String(format: "%.1fs",t)) }
    private func playhead(x: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color.white).frame(width: 2).shadow(color: .black.opacity(0.5),radius: 2)
            RoundedRectangle(cornerRadius: 3).fill(Color.white).frame(width: 12,height: 14).shadow(color: .black.opacity(0.4),radius: 2,y: 1)
        }.frame(width: 12,height: totalHeight).offset(x: x-6).allowsHitTesting(false)
    }

    // MARK: Clip track

    private func clipTrack(width: CGFloat,x: @escaping (Double) -> CGFloat,time: @escaping (CGFloat) -> Double) -> some View {
        let cuts = displayedCuts
        return ZStack(alignment: .topLeading) {
            // Removed ranges: hatched.
            RoundedRectangle(cornerRadius: 10,style: .continuous).fill(Color.white.opacity(0.03))
            Hatch().stroke(Color.white.opacity(0.07),lineWidth: 1).clipShape(RoundedRectangle(cornerRadius: 10,style: .continuous))
            // Retained ranges sit on an opaque base so the hatching only shows where footage was removed.
            ForEach(cuts) { cut in RoundedRectangle(cornerRadius: 9,style: .continuous).fill(StudioTheme.elevated).frame(width: max(2,x(cut.end)-x(cut.start)),height: clipHeight).offset(x: x(cut.start)) }
            // Filmstrip, shown only inside retained ranges.
            // Frames at their natural aspect, as many as fit side by side (like an editor's filmstrip).
            let aspect = CGFloat(project.width)/CGFloat(max(1,project.height))
            let slots = max(1,Int((width/(clipHeight*aspect)).rounded()))
            HStack(spacing: 0) {
                ForEach(0..<(filmstrip.frames.isEmpty ? 0 : slots),id: \.self) { slot in
                    let frame = filmstrip.frames[min(filmstrip.frames.count-1,Int((Double(slot)+0.5)/Double(slots)*Double(filmstrip.frames.count)))]
                    Image(decorative: frame,scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                        .frame(width: width/CGFloat(slots),height: clipHeight).clipped()
                        .overlay(Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1),alignment: .trailing)
                }
            }.frame(width: width,height: clipHeight,alignment: .leading).opacity(0.9)
            .mask { ZStack(alignment: .topLeading) { ForEach(cuts) { cut in RoundedRectangle(cornerRadius: 9,style: .continuous).frame(width: max(2,x(cut.end)-x(cut.start)),height: clipHeight).offset(x: x(cut.start)) } }.frame(width: width,height: clipHeight,alignment: .topLeading) }
            ForEach(cuts) { cut in
                let selected = store.selectedCut == cut.id
                let w = max(2,x(cut.end)-x(cut.start))
                ZStack {
                    RoundedRectangle(cornerRadius: 9,style: .continuous).fill(LinearGradient(colors: [Color.white.opacity(0.06),Color.black.opacity(0.18)],startPoint: .top,endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 9,style: .continuous).strokeBorder(StudioTheme.clipEdge.opacity(selected ? 0.95 : 0.3),lineWidth: selected ? 2 : 1)
                    HStack(spacing: 4) { Image(systemName: "film"); Text(clock(cut.duration)).monospacedDigit() }
                        .font(.system(size: 10,weight: .semibold)).foregroundStyle(.white).padding(.horizontal,7).padding(.vertical,3)
                        .background(.black.opacity(0.45),in: Capsule()).opacity(w > 70 ? 1 : 0)
                        .frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading).padding(6)
                }
                .frame(width: w,height: clipHeight).offset(x: x(cut.start))
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .named("clip")) { location in
                    store.selectedCut = cut.id; store.inspectorTab = .cut; store.seekSource(time(location.x))
                }
                edgeHandle(selected: selected).offset(x: x(cut.start)-1).gesture(cutEdgeDrag(cut,.start,time: time))
                edgeHandle(selected: selected).offset(x: x(cut.end)-9).gesture(cutEdgeDrag(cut,.end,time: time))
            }
        }.frame(width: width,height: clipHeight,alignment: .topLeading).coordinateSpace(name: "clip")
    }
    private var displayedCuts: [Cut] {
        guard let drag = cutDrag else { return project.cuts }
        return project.cuts.map { cut in
            guard cut.id == drag.id else { return cut }
            var next = cut; if drag.edge == .start { next.start = drag.value } else { next.end = drag.value }; return next
        }
    }
    private func edgeHandle(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(StudioTheme.clipEdge.opacity(selected ? 0.95 : 0.0001))
            .frame(width: 10,height: clipHeight-14).padding(.vertical,7)
            .overlay(Capsule().fill(Color.black.opacity(0.35)).frame(width: 2,height: 14).opacity(selected ? 1 : 0))
            .contentShape(Rectangle().inset(by: -4))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }
    private func cutEdgeDrag(_ cut: Cut,_ edge: Edge,time: @escaping (CGFloat) -> Double) -> some Gesture {
        DragGesture(minimumDistance: 1,coordinateSpace: .named("clip")).onChanged { value in
            let cuts = project.cuts, i = cuts.firstIndex { $0.id == cut.id } ?? 0
            let t = time(value.location.x)
            let clamped = edge == .start ? min(cut.end-0.1,max(i > 0 ? cuts[i-1].end : 0,t)) : max(cut.start+0.1,min(i+1 < cuts.count ? cuts[i+1].start : project.duration,t))
            cutDrag = (cut.id,edge,clamped)
            store.selectedCut = cut.id
            store.seekSource(clamped)
        }.onEnded { _ in
            guard let drag = cutDrag else { return }
            cutDrag = nil
            store.edit { p in if let i = p.cuts.firstIndex(where: { $0.id == drag.id }) { if drag.edge == .start { p.cuts[i].start = drag.value } else { p.cuts[i].end = drag.value } } }
        }
    }

    // MARK: Zoom track

    private func zoomTrack(width: CGFloat,x: @escaping (Double) -> CGFloat,time: @escaping (CGFloat) -> Double) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9,style: .continuous).fill(Color.white.opacity(0.025))
                .contentShape(Rectangle())
                .onTapGesture(count: 2,coordinateSpace: .named("zoom")) { location in store.seekSource(time(location.x)); store.addZoom() }
                .help("Doppelklick fügt hier einen Zoom hinzu")
            ForEach(project.zooms) { zoom in
                let range = zoomDrag?.id == zoom.id ? (zoomDrag!.start,zoomDrag!.end) : (zoom.start,zoom.end)
                let selected = store.selectedZoom == zoom.id
                let w = max(6,x(range.1)-x(range.0))
                ZStack {
                    RoundedRectangle(cornerRadius: 8,style: .continuous).fill(StudioTheme.zoomTrack).opacity(selected ? 1 : 0.78)
                    RoundedRectangle(cornerRadius: 8,style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.9 : 0.18),lineWidth: selected ? 1.5 : 1)
                    HStack(spacing: 4) {
                        Image(systemName: zoom.followsCursor ? "cursorarrow.motionlines" : "scope").font(.system(size: 9,weight: .bold))
                        Text(String(format: "%.1f×",zoom.scale)).font(.system(size: 10,weight: .bold)).monospacedDigit()
                    }.foregroundStyle(.white).opacity(w > 54 ? 1 : 0)
                }
                .frame(width: w,height: zoomHeight).offset(x: x(range.0))
                .contentShape(Rectangle())
                .onTapGesture { store.selectedZoom = zoom.id; store.inspectorTab = .zoom; store.seekSource((zoom.start+zoom.end)/2) }
                .gesture(DragGesture(minimumDistance: 2,coordinateSpace: .named("zoom")).onChanged { value in
                    let length = zoom.end-zoom.start
                    let start = min(project.duration-length,max(0,zoom.start+Double(value.translation.width/width)*project.duration))
                    zoomDrag = (zoom.id,start,start+length); store.selectedZoom = zoom.id
                }.onEnded { _ in commitZoomDrag() })
                zoomEdge.offset(x: x(range.0)-2).gesture(zoomEdgeDrag(zoom,.start,time: time))
                zoomEdge.offset(x: x(range.1)-8).gesture(zoomEdgeDrag(zoom,.end,time: time))
            }
        }.frame(width: width,height: zoomHeight,alignment: .topLeading).coordinateSpace(name: "zoom")
    }
    private var zoomEdge: some View {
        Rectangle().fill(Color.white.opacity(0.0001)).frame(width: 10,height: zoomHeight)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }
    private func zoomEdgeDrag(_ zoom: ZoomSegment,_ edge: Edge,time: @escaping (CGFloat) -> Double) -> some Gesture {
        DragGesture(minimumDistance: 1,coordinateSpace: .named("zoom")).onChanged { value in
            let t = time(value.location.x)
            let start = edge == .start ? min(zoom.end-0.2,max(0,t)) : zoom.start
            let end = edge == .end ? max(zoom.start+0.2,min(project.duration,t)) : zoom.end
            zoomDrag = (zoom.id,start,end); store.selectedZoom = zoom.id
        }.onEnded { _ in commitZoomDrag() }
    }
    private func commitZoomDrag() {
        guard let drag = zoomDrag else { return }
        zoomDrag = nil
        store.edit { p in if let i = p.zooms.firstIndex(where: { $0.id == drag.id }) { p.zooms[i].start = drag.start; p.zooms[i].end = drag.end } }
        store.inspectorTab = .zoom
    }

    // MARK: Camera layout track

    private func layoutTrack(width: CGFloat,x: @escaping (Double) -> CGFloat,time: @escaping (CGFloat) -> Double) -> some View {
        let segments = (project.cameraLayouts ?? []).sorted { $0.start < $1.start }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7,style: .continuous).fill(Color.white.opacity(0.02))
                .overlay(alignment: .leading) {
                    if segments.isEmpty { Label("Kamera schwebt · Doppelklick: Geteilt",systemImage: "person.crop.square").font(.system(size: 9,weight: .medium)).foregroundStyle(StudioTheme.textTertiary.opacity(0.7)).padding(.leading,8) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2,coordinateSpace: .named("layout")) { location in store.seekSource(time(location.x)); store.addCameraLayout(.split) }
                .help("Doppelklick: Kamera hier neben den Bildschirm setzen")
            ForEach(segments) { segment in
                let range = layoutDrag?.id == segment.id ? (layoutDrag!.start,layoutDrag!.end) : (segment.start,segment.end)
                let selected = store.selectedLayout == segment.id
                let w = max(6,x(range.1)-x(range.0)), color = layoutColor(segment.layout)
                ZStack {
                    RoundedRectangle(cornerRadius: 7,style: .continuous).fill(color.opacity(selected ? 0.85 : 0.55))
                    RoundedRectangle(cornerRadius: 7,style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.9 : 0.15),lineWidth: selected ? 1.5 : 1)
                    HStack(spacing: 4) { Image(systemName: segment.layout.icon).font(.system(size: 9,weight: .bold)); Text(segment.layout.label).font(.system(size: 9,weight: .bold)) }
                        .foregroundStyle(.white).opacity(w > 74 ? 1 : 0)
                }
                .frame(width: w,height: layoutHeight).offset(x: x(range.0))
                .contentShape(Rectangle())
                .onTapGesture { store.selectedLayout = segment.id; store.inspectorTab = .camera; store.seekSource((segment.start+segment.end)/2) }
                .contextMenu {
                    ForEach(CameraLayout.allCases,id: \.self) { layout in Button(layout.label) { store.setCameraLayout(segment.id,layout) } }
                    Divider()
                    Button("Entfernen",role: .destructive) { store.removeCameraLayout(segment.id) }
                }
                .gesture(DragGesture(minimumDistance: 2,coordinateSpace: .named("layout")).onChanged { value in
                    let (low,high) = neighbours(of: segment,in: segments), length = segment.end-segment.start
                    let start = min(high-length,max(low,segment.start+Double(value.translation.width/width)*project.duration))
                    layoutDrag = (segment.id,start,start+length); store.selectedLayout = segment.id
                }.onEnded { _ in commitLayoutDrag() })
                layoutEdge.offset(x: x(range.0)-2).gesture(layoutEdgeDrag(segment,.start,segments: segments,time: time))
                layoutEdge.offset(x: x(range.1)-8).gesture(layoutEdgeDrag(segment,.end,segments: segments,time: time))
            }
        }.frame(width: width,height: layoutHeight,alignment: .topLeading).coordinateSpace(name: "layout")
    }
    /// Free room around a layout segment: segments never overlap.
    private func neighbours(of segment: CameraLayoutSegment,in segments: [CameraLayoutSegment]) -> (Double,Double) {
        let low = segments.filter { $0.id != segment.id && $0.end <= segment.start+0.001 }.map(\.end).max() ?? 0
        let high = segments.filter { $0.id != segment.id && $0.start >= segment.end-0.001 }.map(\.start).min() ?? project.duration
        return (low,high)
    }
    private var layoutEdge: some View {
        Rectangle().fill(Color.white.opacity(0.0001)).frame(width: 10,height: layoutHeight)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }
    private func layoutEdgeDrag(_ segment: CameraLayoutSegment,_ edge: Edge,segments: [CameraLayoutSegment],time: @escaping (CGFloat) -> Double) -> some Gesture {
        DragGesture(minimumDistance: 1,coordinateSpace: .named("layout")).onChanged { value in
            let (low,high) = neighbours(of: segment,in: segments), t = time(value.location.x)
            let start = edge == .start ? min(segment.end-0.2,max(low,t)) : segment.start
            let end = edge == .end ? max(segment.start+0.2,min(high,t)) : segment.end
            layoutDrag = (segment.id,start,end); store.selectedLayout = segment.id
        }.onEnded { _ in commitLayoutDrag() }
    }
    private func commitLayoutDrag() {
        guard let drag = layoutDrag else { return }
        layoutDrag = nil
        store.edit { p in if let i = p.cameraLayouts?.firstIndex(where: { $0.id == drag.id }) { p.cameraLayouts?[i].start = drag.start; p.cameraLayouts?[i].end = drag.end } }
        store.inspectorTab = .camera
    }
}

/// Diagonal hatching for removed ranges.
private struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX-rect.height
        while x < rect.maxX { path.move(to: CGPoint(x: x,y: rect.maxY)); path.addLine(to: CGPoint(x: x+rect.height,y: rect.minY)); x += 8 }
        return path
    }
}
