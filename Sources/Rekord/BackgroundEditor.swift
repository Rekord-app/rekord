import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import RecorderCore

private enum BackdropTab: String,CaseIterable { case presets = "Vorlagen", color = "Farbe", image = "Bild" }

/// Small rendered previews of the studio wallpapers (the real renderer, not an approximation).
@MainActor private enum WallpaperThumbnails {
    static var images: [Background:CGImage] = [:]
    static func image(_ background: Background) -> CGImage? {
        if let image = images[background] { return image }
        let image = background.art?.image(width: 192,height: 108)
        images[background] = image
        return image
    }
}

struct BackgroundEditor: View {
    @EnvironmentObject var store: EditorStore
    @State private var tab: BackdropTab = .presets
    @State private var customGradient = false
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            Text("Hintergrund").font(.system(size: 12,weight: .semibold))
            Segmented(options: BackdropTab.allCases.map { ($0,$0.rawValue) },selection: Binding(get: { tab },set: select))
            switch tab {
            case .presets: gradients
            case .color:
                ColorPicker("Hintergrundfarbe",selection: color(\.start,kind: .solid),supportsOpacity: false).font(.caption)
            case .image:
                if store.project?.style.backdrop?.kind == .image {
                    Label("Eigenes Bild",systemImage: "photo.fill").font(.caption).foregroundStyle(.secondary)
                    control("Weichzeichnen",value: backdrop(\.blur),range: 0...0.05,display: "\(Int((store.project?.style.backdrop?.blur ?? 0)*2000)) %")
                    Text("Das Bild füllt die Fläche und wird mittig zugeschnitten. Es wird im Projekt mitgespeichert.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button { store.importBackgroundImage() } label: { Label(store.project?.style.backdrop?.kind == .image ? "Anderes Bild auswählen …" : "Eigenes Bild auswählen …",systemImage: "photo.badge.plus").frame(maxWidth: .infinity) }
            }
        }
        .onAppear { synchronize() }
        .onChange(of: store.project?.style.backdrop?.kind) { synchronize() }
        .onChange(of: customGradient) {
            if customGradient,store.project?.style.backdrop == nil {
                store.edit { project in
                    var next = BackdropSettings(kind: .gradient)
                    next.start = project.style.background.palette.first!; next.end = project.style.background.palette.last!
                    project.style.backdrop = next
                }
            }
        }
    }
    private var gradients: some View {
        VStack(alignment: .leading,spacing: 14) {
            Text("Studio · mit Licht und feinem Korn, ideal für YouTube").font(.system(size: 10,weight: .medium)).foregroundStyle(.secondary)
            swatches(Background.allCases.filter(\.isStudio))
            Text("Klassische Verläufe").font(.system(size: 10,weight: .medium)).foregroundStyle(.secondary)
            swatches(Background.allCases.filter { !$0.isStudio })
            customGradientEditor
        }
    }
    private func swatches(_ backgrounds: [Background]) -> some View {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 8),count: 3),spacing: 10) {
                ForEach(backgrounds,id: \.self) { background in
                    Button {
                        customGradient = false
                        store.edit { $0.style.background = background; $0.style.backdrop = nil }
                    } label: {
                        VStack(spacing: 5) {
                            Group {
                                if let image = WallpaperThumbnails.image(background) {
                                    Image(decorative: image,scale: 1).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    LinearGradient(colors: background.palette.map { Color(red: $0.red,green: $0.green,blue: $0.blue) },startPoint: .topLeading,endPoint: .bottomTrailing)
                                }
                            }
                                .frame(height: 40).clipShape(RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected(background) ? .white.opacity(0.9) : .white.opacity(0.08),lineWidth: selected(background) ? 2 : 1))
                                .overlay { if selected(background) { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white).shadow(radius: 3) } }
                            Text(background.title).font(.system(size: 9)).foregroundStyle(selected(background) ? .primary : .secondary)
                        }
                    }.buttonStyle(.plain).accessibilityLabel(background.title).accessibilityAddTraits(selected(background) ? [.isSelected] : [])
                }
            }
    }
    private var customGradientEditor: some View {
            DisclosureGroup(isExpanded: $customGradient) {
                VStack(alignment: .leading,spacing: 14) {
                    ColorPicker("Erste Farbe",selection: color(\.start,kind: .gradient),supportsOpacity: false)
                    ColorPicker("Zweite Farbe",selection: color(\.end,kind: .gradient),supportsOpacity: false)
                    control("Richtung",value: backdrop(\.angle),range: 0...360,display: "\(Int(store.project?.style.backdrop?.angle ?? 45))°")
                }.font(.caption).padding(.top,14)
            } label: { Text("Eigenen Verlauf erstellen").font(.system(size: 11)) }
    }
    private func selected(_ background: Background) -> Bool { store.project?.style.backdrop == nil && store.project?.style.background == background }
    private func select(_ value: BackdropTab) {
        tab = value
        if value == .presets { store.edit { $0.style.backdrop = nil } }
        if value == .color {
            store.edit { project in
                var next = project.style.backdrop ?? BackdropSettings(kind: .solid)
                next.kind = .solid; project.style.backdrop = next
            }
        }
    }
    private func synchronize() {
        switch store.project?.style.backdrop?.kind {
        case .solid: tab = .color
        case .image: tab = .image
        case .gradient: tab = .presets; customGradient = true
        case nil: tab = .presets
        }
    }
    private func color(_ path: WritableKeyPath<BackdropSettings,RGB>,kind: BackdropKind) -> Binding<Color> {
        Binding(get: {
            let value = (store.project?.style.backdrop ?? BackdropSettings(kind: kind))[keyPath: path]
            return Color(red: value.red,green: value.green,blue: value.blue)
        },set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            store.edit { project in
                var next = project.style.backdrop ?? BackdropSettings(kind: kind)
                next.kind = kind; next[keyPath: path] = RGB(rgb.redComponent,rgb.greenComponent,rgb.blueComponent); project.style.backdrop = next
            }
        })
    }
    private func backdrop(_ path: WritableKeyPath<BackdropSettings,Double>) -> Binding<Double> {
        Binding(get: { (store.project?.style.backdrop ?? BackdropSettings(kind: .gradient))[keyPath: path] },set: { value in
            store.edit { project in
                var next = project.style.backdrop ?? BackdropSettings(kind: .gradient); next[keyPath: path] = value; project.style.backdrop = next
            }
        })
    }
    private func control(_ name: String,value: Binding<Double>,range: ClosedRange<Double>,display: String) -> some View {
        VStack(alignment: .leading,spacing: 6) {
            HStack { Text(name); Spacer(); Text(display).foregroundStyle(.secondary).monospacedDigit() }.font(.caption)
            Slider(value: value,in: range).accessibilityLabel(name)
        }
    }
}

extension EditorStore {
    func importBackgroundImage() {
        guard phase == .idle,let directory else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.message = "Eigenes Hintergrundbild auswählen. Eine Kopie wird im Videoprojekt gespeichert."
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                    kCGImageSourceCreateThumbnailFromImageAlways:true,
                    kCGImageSourceCreateThumbnailWithTransform:true,
                    kCGImageSourceThumbnailMaxPixelSize:4096
                  ] as CFDictionary) else { throw RecorderError.message("Dieses Hintergrundbild kann nicht geöffnet werden.") }
            let name = "background-\(UUID().uuidString).png", destination = directory.appendingPathComponent(name)
            guard let output = CGImageDestinationCreateWithURL(destination as CFURL,UTType.png.identifier as CFString,1,nil) else { throw RecorderError.message("Hintergrundbild konnte nicht gespeichert werden.") }
            CGImageDestinationAddImage(output,image,nil)
            guard CGImageDestinationFinalize(output) else { throw RecorderError.message("Hintergrundbild konnte nicht gespeichert werden.") }
            edit { project in
                var next = BackdropSettings(kind: .image); next.imageFile = name; project.style.backdrop = next
            }
            status = "Eigenes Hintergrundbild übernommen"
        } catch { self.error = error.localizedDescription }
    }
}
