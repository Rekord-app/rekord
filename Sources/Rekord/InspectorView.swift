import SwiftUI
import RecorderCore

enum InspectorTab: String, CaseIterable {
    case appearance = "Look", cursor = "Cursor", camera = "Kamera", zoom = "Zoom", cut = "Schnitt", export = "Export"
    var icon: String {
        switch self {
        case .appearance: return "paintpalette"
        case .cursor: return "cursorarrow.rays"
        case .camera: return "video"
        case .zoom: return "plus.magnifyingglass"
        case .cut: return "scissors"
        case .export: return "square.and.arrow.up"
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(alignment: .leading,spacing: 0) {
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases,id: \.self) { tab in
                    let selected = store.inspectorTab == tab
                    Button { withAnimation(.snappy(duration: 0.18)) { store.inspectorTab = tab } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon).font(.system(size: 14,weight: .medium)).frame(height: 18).foregroundStyle(selected ? StudioTheme.accent : StudioTheme.textSecondary)
                            Text(tab.rawValue).font(.system(size: 9,weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(selected ? StudioTheme.text : StudioTheme.textSecondary)
                        }.frame(maxWidth: .infinity).padding(.vertical,8)
                        .background(selected ? StudioTheme.fillHover : .clear,in: RoundedRectangle(cornerRadius: 9,style: .continuous))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(tab.rawValue).accessibilityLabel(tab.rawValue).accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }.padding(10)
            Rectangle().fill(StudioTheme.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading,spacing: 22) {
                    switch store.inspectorTab {
                    case .appearance: appearance
                    case .cursor: cursorEditor
                    case .camera: cameraEditor
                    case .cut: cutEditor
                    case .zoom: zoomEditor
                    case .export: exportOptions
                    }
                }.padding(20).frame(maxWidth: .infinity,alignment: .leading)
            }
        }.background(StudioTheme.sidebar).tint(StudioTheme.controlTint)
    }
    private var appearance: some View {
        VStack(alignment: .leading,spacing: 20) {
            toolHeading("Hintergrund & Rahmen",subtitle: "Wie dein Bildschirm im Video sitzt. Format und Ausschnitt oben über der Vorschau.")
            BackgroundEditor()
            Divider()
            HStack(spacing: 5) {
                framingButton("Randlos",padding: 0,corners: 0,shadow: 0)
                framingButton("Dezent",padding: 0.035,corners: 0.015,shadow: 0.25)
                framingButton("Weich",padding: 0.065,corners: 0.03,shadow: 0.5)
                framingButton("Präsent",padding: 0.11,corners: 0.045,shadow: 0.65)
            }
            control("Abstand zum Rand",value: style(\.padding),range: 0...0.2)
            control("Abgerundete Ecken",value: style(\.cornerRadius),range: 0...0.08)
            control("Schatten",value: style(\.shadow),range: 0...1)
        }
    }
    private var cursorEditor: some View {
        VStack(alignment: .leading,spacing: 18) {
            toolHeading("Cursor",subtitle: "Wird aus den Mausdaten neu gezeichnet: immer scharf, ruhig geführt.")
            Toggle("Cursor anzeigen",isOn: style(\.showCursor))
            control("Cursorgröße",value: style(\.cursorSize),range: 0.5...2)
            control("Glättung",value: style(\.smoothing),range: 0...0.3)
            control("Neigung beim Bewegen",value: Binding(get: { store.project?.style.cursorTilt ?? Style.defaultCursorTilt },set: { value in store.edit { $0.style.cursorTilt = value } }),range: 0...1)
            VStack(alignment: .leading,spacing: 6) {
                Text("Klick-Effekt").font(.caption)
                Segmented(options: ClickEffect.allCases.map { ($0,$0.label) },selection: Binding(get: { store.project?.style.clickEffect ?? .ring },set: { value in store.edit { $0.style.clickEffect = value } }))
            }
            control("Bewegungsunschärfe",value: Binding(get: { store.project?.style.motionBlur ?? Style.defaultMotionBlur },set: { value in store.edit { $0.style.motionBlur = value } }),range: 0...1)
        }.font(.caption)
    }
    private var cameraEditor: some View {
        VStack(alignment: .leading,spacing: 18) {
            toolHeading("Kamera",subtitle: "Beim Zoomen wird die Kamera automatisch kleiner, damit sie nichts verdeckt.")
            if store.project?.hasCamera == true {
                Toggle("Im Video anzeigen",isOn: style(\.showCamera))
                cameraPresets
                VStack(alignment: .leading,spacing: 6) {
                    Text("Form").font(.caption)
                    Segmented(options: CameraShape.allCases.map { ($0,$0.label) },selection: Binding(get: { store.project.map { $0.style.cameraShape ?? ($0.recordingMode == .loom ? .circle : .rounded) } ?? .rounded },set: { value in store.edit { $0.style.cameraShape = value } }))
                }
                VStack(alignment: .leading,spacing: 6) {
                    Text("Seitenverhältnis").font(.caption)
                    Segmented(options: CameraAspect.allCases.map { ($0,$0.rawValue) },selection: Binding(get: { store.project?.style.cameraAspect ?? .square },set: { value in store.edit { $0.style.cameraAspect = value; if $0.style.cameraShape == .circle && value != .square { $0.style.cameraShape = .rounded } } }))
                }
                Toggle("Spiegeln",isOn: style(\.mirrorCamera))
                Toggle("Weißer Rand",isOn: Binding(get: { store.project?.style.cameraBorder ?? false },set: { value in store.edit { $0.style.cameraBorder = value } }))
                VStack(alignment: .leading,spacing: 8) {
                    Text("Position").font(.caption)
                    HStack(spacing: 8) {
                        ForEach([(Point(0.16,0.19),"arrow.up.left"),(Point(0.84,0.19),"arrow.up.right"),(Point(0.16,0.81),"arrow.down.left"),(Point(0.84,0.81),"arrow.down.right")] as [(Point,String)],id: \.1) { point,icon in
                            let selected = store.project.map { abs($0.style.cameraPosition.x-point.x) < 0.02 && abs($0.style.cameraPosition.y-point.y) < 0.02 } ?? false
                            Button { store.edit { $0.style.cameraPosition = point } } label: {
                                Image(systemName: icon).foregroundStyle(selected ? StudioTheme.accent : StudioTheme.textSecondary).frame(maxWidth: .infinity).frame(height: 30)
                                    .background(selected ? StudioTheme.fillActive : StudioTheme.fill,in: RoundedRectangle(cornerRadius: 8,style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8,style: .continuous).strokeBorder(selected ? StudioTheme.hairlineStrong : .clear))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                control("Kameragröße",value: style(\.cameraSize),range: 0.1...0.5)
                control("Größe beim Zoom",value: Binding(get: { store.project?.style.cameraZoomScale ?? Style.defaultCameraZoomScale },set: { value in store.edit { $0.style.cameraZoomScale = value } }),range: 0.4...1.6)
                Text("Unter 100 % wird die Kamera beim Hineinzoomen kleiner, darüber größer – weich mit der Zoombewegung.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
                DisclosureGroup("Feinposition") {
                    VStack(spacing: 14) {
                        control("Horizontal",value: cameraPoint(\.x),range: 0...1)
                        control("Vertikal",value: cameraPoint(\.y),range: 0...1)
                    }.padding(.top,10)
                }.font(.caption)
                Divider().opacity(0.4)
                cameraLayouts
            } else { Text("Dieses Video wurde ohne Kamera aufgenommen. Aktiviere sie vor deiner nächsten Aufnahme.").font(.caption).foregroundStyle(.secondary) }
        }.font(.caption)
    }
    /// One-click looks with a small preview of shape and proportions.
    private var cameraPresets: some View {
        VStack(alignment: .leading,spacing: 6) {
            Text("Stil").font(.caption)
            HStack(spacing: 6) {
                ForEach(CameraPreset.allCases,id: \.self) { preset in
                    let active = store.project.map { project -> Bool in
                        var probe = project.style; preset.apply(to: &probe)
                        let s = project.style
                        return probe.cameraShape == s.cameraShape && probe.cameraAspect == (s.cameraAspect ?? .square) && probe.cameraBorder == (s.cameraBorder ?? false) && abs(probe.cameraSize-s.cameraSize) < 0.005
                    } ?? false
                    Button { store.edit { preset.apply(to: &$0.style) } } label: {
                        VStack(spacing: 5) {
                            presetGlyph(preset).frame(height: 26)
                            Text(preset.label).font(.system(size: 9,weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }.frame(maxWidth: .infinity).padding(.vertical,7)
                        .background(active ? StudioTheme.fillActive : StudioTheme.fill,in: RoundedRectangle(cornerRadius: 9,style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9,style: .continuous).strokeBorder(active ? StudioTheme.hairlineStrong : .clear))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Kamera-Stil \(preset.label)")
                }
            }
        }
    }
    private func presetGlyph(_ preset: CameraPreset) -> some View {
        var probe = Style(); preset.apply(to: &probe)
        let ratio = probe.cameraShape == .circle ? 1 : (probe.cameraAspect ?? .square).ratio
        let w: CGFloat = ratio >= 1 ? 26 : 26*ratio, h: CGFloat = ratio >= 1 ? 26/ratio : 26
        return ZStack {
            CameraShapeOutline(shape: probe.cameraShape ?? .rounded).fill(LinearGradient(colors: [Color.white.opacity(0.55),Color.white.opacity(0.25)],startPoint: .top,endPoint: .bottom))
            if probe.cameraBorder == true { CameraShapeOutline(shape: probe.cameraShape ?? .rounded).stroke(Color.white,lineWidth: 1.5) }
        }.frame(width: w,height: h)
    }
    /// Where the camera goes over time: full screen, side by side with the screen, or hidden.
    private var cameraLayouts: some View {
        VStack(alignment: .leading,spacing: 8) {
            Text("Layout im Video").font(.system(size: 12,weight: .semibold))
            Text("Ab der Abspielposition: Kamera im Vollbild, neben dem Bildschirm oder ausgeblendet. Außerhalb schwebt sie wie gewohnt.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
            HStack(spacing: 6) {
                ForEach(CameraLayout.allCases,id: \.self) { layout in
                    Button { store.addCameraLayout(layout) } label: {
                        VStack(spacing: 4) { Image(systemName: layout.icon).font(.system(size: 13)); Text(layout == .hidden ? "Ausblenden" : layout.label).font(.system(size: 9,weight: .medium)) }
                            .frame(maxWidth: .infinity).frame(height: 44).background(StudioTheme.fill,in: RoundedRectangle(cornerRadius: 9,style: .continuous)).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("\(layout.label) ab \(clock(store.sourceTime))")
                }
            }
            if let segments = store.project?.cameraLayouts, !segments.isEmpty {
                ForEach(segments.sorted { $0.start < $1.start }) { segment in
                    HStack(spacing: 6) {
                        Button { store.selectedLayout = segment.id; store.seekSource((segment.start+segment.end)/2) } label: {
                            HStack { Image(systemName: segment.layout.icon).foregroundStyle(layoutColor(segment.layout)); Text("\(clock(segment.start)) – \(clock(segment.end))"); Spacer() }
                                .font(.system(size: 10,design: .monospaced)).padding(7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Menu { ForEach(CameraLayout.allCases,id: \.self) { layout in Button(layout.label) { store.setCameraLayout(segment.id,layout) } } } label: { Text(segment.layout.label).font(.system(size: 10)) }
                            .menuStyle(.button).buttonStyle(.plain).fixedSize()
                        Button { store.removeCameraLayout(segment.id) } label: { Image(systemName: "xmark").font(.system(size: 9,weight: .bold)).frame(width: 22,height: 22) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Layout entfernen")
                    }.background(store.selectedLayout == segment.id ? layoutColor(segment.layout).opacity(0.22) : StudioTheme.fill,in: RoundedRectangle(cornerRadius: 7,style: .continuous))
                }
                if let segment = segments.first(where: { $0.id == store.selectedLayout }) {
                    timeField("Start",value: layoutTime(segment.id,\.start))
                    timeField("Ende",value: layoutTime(segment.id,\.end))
                }
            }
        }
    }
    private func layoutTime(_ id: UUID,_ path: WritableKeyPath<CameraLayoutSegment,Double>) -> Binding<Double> {
        Binding(get: { store.project?.cameraLayouts?.first(where: { $0.id == id })?[keyPath: path] ?? 0 },
                set: { value in store.edit { p in
                    guard let i = p.cameraLayouts?.firstIndex(where: { $0.id == id }) else { return }
                    var s = p.cameraLayouts![i]; s[keyPath: path] = min(p.duration,max(0,value))
                    guard s.end-s.start >= 0.2 else { return }
                    p.cameraLayouts![i] = s
                } })
    }
    private var exportOptions: some View {
        VStack(alignment: .leading,spacing: 18) {
            toolHeading("Exportieren & teilen",subtitle: "Erstelle eine Videodatei oder einen abspielbaren Link.")
            Picker("Auflösung",selection: $store.exportHeight) { Text("1080p").tag(1080); Text("4K").tag(2160) }
            Picker("Bildrate",selection: $store.exportFPS) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
            Button { store.export() } label: { Label("MP4 speichern",systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }.buttonStyle(PillButtonStyle(height: 34,prominent: true))
            Text("H.264-Video mit AAC-Ton. Der Export läuft im Hintergrund mit dem aktuellen Stand; du kannst weiter schneiden oder aufnehmen.").font(.system(size: 11)).foregroundStyle(.secondary)
            ExportQueueView(queue: store.exports)
            Divider()
            Button { store.share() } label: { Label("Per Link teilen",systemImage: "link").frame(maxWidth: .infinity) }.buttonStyle(AccentButtonStyle(height: 34))
            Text("Wer den Link hat, kann das Video ansehen. Du kannst Freigaben später deaktivieren.").font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Freigaben verwalten") { store.showShareSettings = true }.buttonStyle(.pill)
            Divider()
            Button("Originalprojekt im Finder") { store.revealProject() }.buttonStyle(.pill)
        }.font(.caption)
    }
    private func toolHeading(_ title: String,subtitle: String) -> some View {
        VStack(alignment: .leading,spacing: 6) {
            Text(title).font(StudioFont.title).foregroundStyle(StudioTheme.text)
            Text(subtitle).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false,vertical: true)
        }
    }
    /// Which part of the recording is shown. Presets are computed for the project's source size.
    private var cropPicker: some View {
        let project = store.project
        let current: CropRect.Preset = {
            guard let project, let crop = project.style.crop else { return .original }
            return CropRect.Preset.allCases.first { CropRect.preset($0,sourceWidth: project.width,sourceHeight: project.height) == crop } ?? .original
        }()
        let isWidescreen = project.map { abs(Double($0.width)/Double($0.height)-16.0/9.0) <= 0.01 } ?? true
        return VStack(alignment: .leading,spacing: 6) {
            Picker("Ausschnitt",selection: Binding(get: { current },set: { preset in
                store.edit { $0.style.crop = CropRect.preset(preset,sourceWidth: $0.width,sourceHeight: $0.height) }
            })) {
                Text("Ganze Aufnahme").tag(CropRect.Preset.original)
                Text("16:9 · ohne Menüleiste & Dock").tag(CropRect.Preset.widescreenWithoutMenuBar)
                Text("16:9 · mittig").tag(CropRect.Preset.widescreenCentered)
            }.disabled(isWidescreen)
            Text(isWidescreen ? "Die Aufnahme ist bereits 16:9." : "Für ein bildfüllendes 16:9-Video: Ausschnitt wählen, Format 16:9 und Rahmen „Randlos“.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
        }
    }
    private func framingButton(_ title: String,padding: Double,corners: Double,shadow: Double) -> some View {
        let active = store.project.map { abs($0.style.padding-padding) < 0.002 && abs($0.style.cornerRadius-corners) < 0.002 && abs($0.style.shadow-shadow) < 0.02 } ?? false
        return Button { store.edit { $0.style.padding = padding; $0.style.cornerRadius = corners; $0.style.shadow = shadow } } label: {
            Text(title).font(.system(size: 10.5,weight: .medium)).foregroundStyle(active ? StudioTheme.text : StudioTheme.textSecondary).frame(maxWidth: .infinity).frame(height: 26)
                .background(active ? StudioTheme.fillActive : StudioTheme.fill,in: Capsule()).overlay(Capsule().strokeBorder(active ? StudioTheme.hairlineStrong : StudioTheme.hairline)).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? [.isSelected] : [])
    }
    private var cutEditor: some View {
        VStack(alignment: .leading,spacing: 10) {
            toolHeading("Video schneiden",subtitle: "Abschnitt auswählen, Grenzen setzen oder unerwünschte Teile entfernen.")
            if let p = store.project, let i = p.cuts.firstIndex(where: { $0.id == store.selectedCut }) {
                let c = p.cuts[i]
                Text("Segment \(i+1) · \(clock(c.duration))").font(.caption)
                timeField("Start",value: Binding(get: { store.project?.cuts.first(where: { $0.id == c.id })?.start ?? 0 },set: { v in
                    store.pause(); store.edit { project in if let j = project.cuts.firstIndex(where: { $0.id == c.id }) { project.cuts[j].start = min(project.cuts[j].end-0.05,max(j > 0 ? project.cuts[j-1].end : 0,v)) } }
                }))
                timeField("Ende",value: Binding(get: { store.project?.cuts.first(where: { $0.id == c.id })?.end ?? 0 },set: { v in
                    store.pause(); store.edit { project in if let j = project.cuts.firstIndex(where: { $0.id == c.id }) { project.cuts[j].end = max(project.cuts[j].start+0.05,min(j+1 < project.cuts.count ? project.cuts[j+1].start : project.duration,v)) } }
                }))
                HStack { Button("Hier schneiden") { store.split() }.buttonStyle(.pill); Button("Löschen",role: .destructive) { store.deleteCut() }.buttonStyle(.pill).disabled(p.cuts.count <= 1) }
            } else { Text("Segment in der Timeline auswählen.").font(.caption).foregroundStyle(.secondary) }
            Divider().padding(.vertical,6)
            Button { store.resetCuts() } label: { Label("Alle Schnitte zurücksetzen",systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity) }.buttonStyle(.pill)
                .disabled((store.project?.cuts.count ?? 1) <= 1 && store.project?.cuts.first.map { $0.start == 0 && abs($0.end-(store.project?.duration ?? 0)) < 0.001 } == true)
                .help("Ganze Aufnahme wieder verwenden (auch herausgeschnittene Pausen)")
        }
    }
    /// Strength and timing of automatic click zooms; applying regenerates them (manual zoom edits are replaced).
    private var autoZoomSettings: some View {
        let settings = store.project?.autoZoom ?? .standard
        func binding(_ path: WritableKeyPath<AutoZoomSettings,Double>) -> Binding<Double> {
            Binding(get: { (store.project?.autoZoom ?? .standard)[keyPath: path] },set: { value in
                var next = store.project?.autoZoom ?? .standard; next[keyPath: path] = value
                store.edit { $0.autoZoom = next }
            })
        }
        return VStack(alignment: .leading,spacing: 12) {
            Text("Automatische Klick-Zooms").font(.system(size: 12,weight: .semibold))
            control("Zoomstärke",value: binding(\.scale),range: 1.25...4)
            control("Vorlauf vor dem Klick",value: binding(\.lead),range: 0...1.5)
            control("Haltezeit nach dem Klick",value: binding(\.hold),range: 0.5...5)
            Button("Klick-Zooms neu erzeugen") { store.autoZoom(settings) }.buttonStyle(PillButtonStyle(height: 28,prominent: true))
                .help("Erzeugt alle Klick-Zooms mit diesen Einstellungen neu und ersetzt manuelle Zoom-Änderungen.")
            Divider()
        }
    }
    private var zoomEditor: some View {
        VStack(alignment: .leading,spacing: 10) {
            HStack { Text("Zooms").font(StudioFont.title).foregroundStyle(StudioTheme.text); Spacer(); Button { store.addZoom() } label: { Image(systemName: "plus") }.buttonStyle(IconButtonStyle(size: 26)).help("Zoom an der Abspielposition").accessibilityLabel("Zoom hinzufügen") }
            autoZoomSettings
            if let p = store.project {
                if !p.zooms.isEmpty {
                    HStack {
                        Text("\(p.zooms.count) Zoom\(p.zooms.count == 1 ? "" : "s")").font(.system(size: 12,weight: .semibold))
                        Spacer()
                        Button(role: .destructive) { store.removeAllZooms() } label: { Label("Alle entfernen",systemImage: "trash") }.font(.caption)
                    }
                }
                ForEach(p.zooms) { z in
                    HStack(spacing: 6) {
                        Button { store.selectedZoom = z.id; store.seekSource((z.start+z.end)/2) } label: {
                            HStack { Image(systemName: z.followsCursor ? "cursorarrow.motionlines" : "scope").foregroundStyle(store.selectedZoom == z.id ? StudioTheme.accent : StudioTheme.textSecondary); Text("\(clock(z.start)) – \(clock(z.end))"); Spacer(); Text(String(format:"%.1f×",z.scale)) }
                                .font(.system(size: 10,design: .monospaced)).padding(7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { store.edit { $0.zooms.removeAll { $0.id == z.id } }; if store.selectedZoom == z.id { store.selectedZoom = nil } } label: { Image(systemName: "xmark").font(.system(size: 9,weight: .bold)).frame(width: 22,height: 22) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Diesen Zoom entfernen")
                    }.background(store.selectedZoom == z.id ? StudioTheme.fillActive : StudioTheme.fill,in: RoundedRectangle(cornerRadius: 7,style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7,style: .continuous).strokeBorder(store.selectedZoom == z.id ? StudioTheme.hairlineStrong : .clear))
                }
                if let z = p.zooms.first(where: { $0.id == store.selectedZoom }) {
                    timeField("Start",value: zoom(z.id,\.start))
                    timeField("Ende",value: zoom(z.id,\.end))
                    control("Zoom",value: zoom(z.id,\.scale),range: 1...4)
                    Toggle("Cursor folgen",isOn: Binding(get: { store.project?.zooms.first(where: { $0.id == z.id })?.followsCursor ?? true },set: { v in store.edit { if let i = $0.zooms.firstIndex(where: { $0.id == z.id }) { $0.zooms[i].followsCursor = v } } }))
                    if !z.followsCursor {
                        control("Fokus X",value: focus(z.id,\.x),range: 0...1)
                        control("Fokus Y",value: focus(z.id,\.y),range: 0...1)
                    }
                    Button("Zoom löschen",role: .destructive) { store.edit { $0.zooms.removeAll { $0.id == z.id } }; store.selectedZoom = nil }
                }
                if p.zooms.isEmpty { Text("Klick-Zooms erscheinen nach der Aufnahme. Du kannst auch manuelle Zooms anlegen.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func style<T>(_ path: WritableKeyPath<Style,T>) -> Binding<T> {
        Binding(get: { (store.project?.style ?? Style())[keyPath: path] },set: { value in store.edit { $0.style[keyPath: path] = value } })
    }
    private func cameraPoint(_ path: WritableKeyPath<Point,Double>) -> Binding<Double> {
        Binding(get: { (store.project?.style.cameraPosition ?? .center)[keyPath: path] },set: { value in store.edit { $0.style.cameraPosition[keyPath: path] = value } })
    }
    private func zoom(_ id: UUID,_ path: WritableKeyPath<ZoomSegment,Double>) -> Binding<Double> {
        Binding(get: { store.project?.zooms.first(where: { $0.id == id })?[keyPath: path] ?? 0 },set: { value in
            store.edit { p in
                guard let i = p.zooms.firstIndex(where: { $0.id == id }) else { return }
                if path == \ZoomSegment.start { p.zooms[i].start = max(0,min(p.zooms[i].end-0.05,value)) }
                else if path == \ZoomSegment.end { p.zooms[i].end = min(p.duration,max(p.zooms[i].start+0.05,value)) }
                else { p.zooms[i][keyPath: path] = value }
            }
        })
    }
    private func focus(_ id: UUID,_ path: WritableKeyPath<Point,Double>) -> Binding<Double> {
        Binding(get: { (store.project?.zooms.first(where: { $0.id == id })?.focus ?? .center)[keyPath: path] },set: { value in store.edit { if let i = $0.zooms.firstIndex(where: { $0.id == id }) { $0.zooms[i].focus[keyPath: path] = value } } })
    }
    private func control(_ name: String,value: Binding<Double>,range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading,spacing: 5) {
            HStack { Text(name); Spacer(); Text(controlValue(name,value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit() }.font(.caption)
            Slider(value: value,in: range).accessibilityLabel(name)
        }
    }
    private func controlValue(_ name: String,_ value: Double) -> String {
        if name == "Abgerundete Ecken" { return "\(Int((value*1080).rounded())) px" }
        if name == "Abstand zum Rand" { return String(format:"%.1f %%",value*100) }
        if name == "Glättung" { return "\(Int(value*1000)) ms" }
        if name == "Zoom" || name == "Zoomstärke" { return String(format:"%.1f×",value) }
        if name == "Vorlauf vor dem Klick" || name == "Haltezeit nach dem Klick" { return String(format:"%.1f s",value) }
        return "\(Int(value*100)) %"
    }
    private func timeField(_ name: String,value: Binding<Double>) -> some View {
        HStack { Text(name).font(.caption); Spacer(); TextField(name,value: value,format: .number.precision(.fractionLength(2))).frame(width: 80).textFieldStyle(.roundedBorder); Text("s").font(.caption).foregroundStyle(.secondary) }
    }
}

func layoutColor(_ layout: CameraLayout) -> Color {
    switch layout {
    case .fullscreen: return Color(red: 0.36,green: 0.78,blue: 0.72)
    case .split: return StudioTheme.info
    case .hidden: return Color(white: 0.55)
    }
}
