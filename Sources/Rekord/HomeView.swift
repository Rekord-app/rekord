import SwiftUI
import AVFoundation
import RecorderCore

/// Start page: the library (all recordings or one folder) grouped by day under a quiet title row with search,
/// and in „Alle Aufnahmen“ the three ways to record (screen, meeting, guide) as one compact strip.
struct HomeView: View {
    @EnvironmentObject var store: EditorStore
    @State private var query = ""
    @State private var titles: [URL: String] = [:]
    @State private var renaming: URL?
    @State private var trashing: URL?
    @State private var newFolderFor: URL?
    @State private var name = ""
    private let columns = [GridItem(.adaptive(minimum: 224,maximum: 300),spacing: 16)]
    private var items: [URL] { store.recordings(inFolder: store.folderFilter) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 28) {
                if store.folderFilter == nil { recordStrip }
                if items.isEmpty, let folder = store.folderFilter {
                    EmptyState(icon: "folder",title: "„\(folder)“ ist noch leer",text: "Zieh Aufnahmen auf den Ordner in der Seitenleiste oder wähle bei einer Aufnahme „In Ordner verschieben“.").padding(.top,40)
                } else if items.isEmpty {
                    EmptyState(icon: "record.circle",title: "Noch keine Aufnahmen",text: "Bildschirm, Fenster oder Bereich wählen, Kamera und Mikro an, los. Zooms, Hintergrund und Schnitt kommen danach automatisch.") {
                        Button { store.openRecorder() } label: { HStack(spacing: 8) { RecordDot(); Text("Erste Aufnahme starten") } }.buttonStyle(.accent).disabled(store.busy)
                    }.padding(.top,40)
                } else if filtered.isEmpty {
                    EmptyState(icon: "magnifyingglass",title: "Nichts gefunden",text: "Keine Aufnahme heißt „\(query)“.").padding(.top,40)
                } else {
                    ForEach(groups,id: \.0) { group,urls in
                        VStack(alignment: .leading,spacing: 12) {
                            GroupHeader(title: group.title,count: urls.count)
                            LazyVGrid(columns: columns,alignment: .leading,spacing: 16) {
                                ForEach(urls,id: \.self) { url in
                                    ProjectCard(url: url,title: titles[url],showFolder: store.folderFilter == nil,
                                                rename: { name = titles[url] ?? RecordingInfo.title(url); renaming = url },
                                                trash: { trashing = url },
                                                newFolder: { name = ""; newFolderFor = url })
                                }
                            }
                        }
                    }
                }
            }.padding(.horizontal,StudioTheme.gutter).padding(.top,4).padding(.bottom,StudioTheme.gutter).frame(maxWidth: 1240,alignment: .leading).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top,spacing: 0) { header }
        .task(id: store.library) { titles = Dictionary(store.library.map { ($0,RecordingInfo.displayTitle(try? Project.load(from: $0),$0)) },uniquingKeysWith: { a,_ in a }) }
        .onChange(of: store.folderFilter) { query = "" }
        .textPrompt("Aufnahme umbenennen",isPresented: Binding(get: { renaming != nil },set: { if !$0 { renaming = nil } }),text: $name,confirm: "Umbenennen") {
            if let url = renaming { store.renameRecording(url,to: name); titles[url] = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        .textPrompt("Neuer Ordner",message: "Die Aufnahme wird direkt hineingelegt.",isPresented: Binding(get: { newFolderFor != nil },set: { if !$0 { newFolderFor = nil } }),text: $name,confirm: "Anlegen") {
            if let url = newFolderFor, let folder = store.createFolder(name) { store.move([url],toFolder: folder.lastPathComponent) }
        }
        .confirmationDialog("„\(trashing.map { titles[$0] ?? RecordingInfo.title($0) } ?? "")“ in den Papierkorb legen?",isPresented: Binding(get: { trashing != nil },set: { if !$0 { trashing = nil } }),titleVisibility: .visible) {
            Button("In den Papierkorb",role: .destructive) { if let url = trashing { store.trash(url) } }
        } message: { Text("Im Finder lässt sich die Aufnahme aus dem Papierkorb zurücklegen. Ein geteilter Link bleibt bestehen, bis du ihn widerrufst.") }
    }
    /// Quiet title row over the scrolling library: where you are, how many, search. No card, no glass.
    private var header: some View {
        HStack(alignment: .firstTextBaseline,spacing: 8) {
            if let folder = store.folderFilter {
                Button { store.showLibrary(folder: nil) } label: { Text("Aufnahmen").font(.system(size: 22,weight: .semibold)).foregroundStyle(StudioTheme.textTertiary) }
                    .buttonStyle(.plain).help("Alle Aufnahmen")
                Image(systemName: "chevron.compact.right").font(.system(size: 15,weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
                Text(folder).font(.system(size: 22,weight: .semibold)).foregroundStyle(StudioTheme.text).lineLimit(1)
            } else {
                Text("Aufnahmen").font(.system(size: 22,weight: .semibold)).foregroundStyle(StudioTheme.text)
            }
            if !items.isEmpty { Text("\(items.count)").font(.system(size: 15,weight: .medium)).monospacedDigit().foregroundStyle(StudioTheme.textTertiary).padding(.leading,2) }
            Spacer(minLength: 16)
            if !items.isEmpty { SearchField(placeholder: "Suchen",text: $query).frame(width: 220) }
        }
        .padding(.horizontal,StudioTheme.gutter+8).padding(.top,20).padding(.bottom,14)
        .frame(maxWidth: 1240+2*StudioTheme.gutter).frame(maxWidth: .infinity)
        .background(StudioTheme.background)
    }
    /// The three recording modes, each one click away.
    private var recordStrip: some View {
        HStack(spacing: 12) {
            RecordEntry(icon: "display",title: "Bildschirm aufnehmen",text: "Studio oder Loom · Bildschirm, Fenster, Bereich",shortcut: "⌘⇧1") { store.openRecorder() }
            RecordEntry(icon: "waveform.badge.mic",title: "Meeting aufnehmen",text: "Audio ab 14.2 · Transkript ab macOS 26",shortcut: "⌃⌥⌘M") { store.showMeetings(); store.meetings.requestStart() }
            RecordEntry(icon: "list.number",title: "Anleitung aufnehmen",text: "Ein Schritt pro Klick, mit Screenshots",shortcut: nil) { store.showGuides(); store.guides.start() }
        }.disabled(store.busy)
    }
    private var filtered: [URL] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { (titles[$0] ?? RecordingInfo.title($0)).lowercased().contains(needle) || (store.folderName(of: $0)?.lowercased().contains(needle) ?? false) }
    }
    private var groups: [(RelativeDay.Group,[URL])] {
        let sorted = filtered.sorted { (RecordingInfo.date($0) ?? .distantPast) > (RecordingInfo.date($1) ?? .distantPast) }
        let grouped = Dictionary(grouping: sorted) { RelativeDay.group(RecordingInfo.date($0) ?? .distantPast) }
        return RelativeDay.Group.allCases.compactMap { group in grouped[group].map { (group,$0) } }
    }
}

/// One entry in the record strip.
private struct RecordEntry: View {
    let icon: String
    let title: String
    let text: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16,weight: .medium)).foregroundStyle(StudioTheme.accent)
                    .frame(width: 36,height: 36).background(StudioTheme.accent.opacity(0.12),in: RoundedRectangle(cornerRadius: 10,style: .continuous))
                VStack(alignment: .leading,spacing: 2) {
                    Text(title).font(StudioFont.heading).foregroundStyle(StudioTheme.text)
                    Text(text).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let shortcut { Text(shortcut).shortcutPill() }
            }
            .padding(.horizontal,14).frame(height: 64).frame(maxWidth: .infinity,alignment: .leading)
            .background(hovering ? StudioTheme.elevated : StudioTheme.surface,in: RoundedRectangle(cornerRadius: StudioTheme.radiusLarge,style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: StudioTheme.radiusLarge,style: .continuous).strokeBorder(hovering ? StudioTheme.hairlineStrong : StudioTheme.hairline))
            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.radiusLarge,style: .continuous))
        }.buttonStyle(.plain).onHover { hovering = $0 }.animation(.easeOut(duration: 0.12),value: hovering)
    }
}

/// Recording card with a frame from the middle of the take, mode badge, length, title and date.
private struct ProjectCard: View {
    @EnvironmentObject var store: EditorStore
    let url: URL
    /// Known title from the library; a change (rename) reloads the card.
    let title: String?
    let showFolder: Bool
    let rename: () -> Void
    let trash: () -> Void
    let newFolder: () -> Void
    @State private var thumbnail: CGImage?
    @State private var info: (title: String,duration: Double,size: String,mode: RecordingMode,camera: Bool)?
    @State private var hovering = false
    var body: some View {
        Button { store.open(url) } label: {
            VStack(alignment: .leading,spacing: 10) {
                ZStack {
                    Rectangle().fill(Color.black.opacity(0.4))
                    if let thumbnail { Image(decorative: thumbnail,scale: 1).resizable().aspectRatio(contentMode: .fill) }
                    else { Image(systemName: "play.rectangle").font(.system(size: 24,weight: .light)).foregroundStyle(StudioTheme.textTertiary) }
                }
                .aspectRatio(16/9,contentMode: .fit).frame(maxWidth: .infinity).clipped()
                .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radius,style: .continuous))
                .overlay(alignment: .topLeading) {
                    if let info {
                        HStack(spacing: 4) {
                            StatusBadge(text: info.mode == .loom ? "Loom" : "Studio",tone: .neutral)
                            if info.camera { Image(systemName: "video.fill").font(.system(size: 9,weight: .bold)).foregroundStyle(StudioTheme.textSecondary).padding(5).background(StudioTheme.fill,in: Circle()) }
                        }.padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let info { Text(clock(info.duration)).font(.system(size: 10,weight: .semibold)).monospacedDigit().foregroundStyle(.white).padding(.horizontal,6).padding(.vertical,3).background(.black.opacity(0.62),in: Capsule()).padding(8) }
                }
                .overlay(RoundedRectangle(cornerRadius: StudioTheme.radius,style: .continuous).strokeBorder(hovering ? StudioTheme.hairlineStrong : StudioTheme.hairline))
                VStack(alignment: .leading,spacing: 3) {
                    Text(info?.title ?? RecordingInfo.title(url)).font(StudioFont.heading).foregroundStyle(StudioTheme.text).lineLimit(1)
                    HStack(spacing: 5) {
                        if showFolder, let folder = store.folderName(of: url) {
                            Label(folder,systemImage: "folder").labelStyle(.titleAndIcon).font(StudioFont.captionStrong).foregroundStyle(StudioTheme.textSecondary)
                            Text("·").foregroundStyle(StudioTheme.textTertiary)
                        }
                        Text([RecordingInfo.date(url).map { RelativeDay.label($0) },info?.size].compactMap { $0 }.joined(separator: " · "))
                    }.font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                }.padding(.horizontal,2)
            }
            .padding(8).background(hovering ? StudioTheme.surface : .clear,in: RoundedRectangle(cornerRadius: StudioTheme.radiusLarge,style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.radiusLarge,style: .continuous))
            .animation(.easeOut(duration: 0.12),value: hovering)
        }.buttonStyle(.plain).onHover { hovering = $0 }.disabled(store.busy)
        .accessibilityLabel("\(info?.title ?? RecordingInfo.title(url)) öffnen")
        .task(id: "\(url.path)|\(title ?? "")") { await load() }
        .draggable(url)
        .contextMenu {
            let locked = store.lockReason(url)
            Button("Öffnen") { store.open(url) }.disabled(store.busy)
            Button("Umbenennen …",action: rename)
            Menu("In Ordner verschieben") {
                let current = store.folderName(of: url)
                Button("Alle Aufnahmen (kein Ordner)") { store.move([url],toFolder: nil) }.disabled(current == nil)
                if !store.folders.isEmpty { Divider() }
                ForEach(store.folders,id: \.self) { folder in
                    Button(folder.lastPathComponent) { store.move([url],toFolder: folder.lastPathComponent) }.disabled(current == folder.lastPathComponent)
                }
                Divider()
                Button("Neuer Ordner …",action: newFolder)
            }.disabled(locked != nil)
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button(locked.map { "In den Papierkorb (\($0))" } ?? "In den Papierkorb …",role: .destructive,action: trash).disabled(locked != nil)
        }
    }
    private func load() async {
        guard let project = try? Project.load(from: url) else { return }
        info = (RecordingInfo.displayTitle(project,url),project.editedDuration,"\(project.width)×\(project.height)",project.recordingMode,project.hasCamera)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url.appendingPathComponent("screen.mov")))
        generator.maximumSize = CGSize(width: 640,height: 640); generator.appliesPreferredTrackTransform = true
        thumbnail = try? await generator.image(at: CMTime(seconds: min(project.duration/2,3),preferredTimescale: 600)).image
    }
}

/// Gives the store access to the main window so the floating recorder can step it back.
struct WindowAccessor: NSViewRepresentable {
    let assign: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { assign(window) } }
        return view
    }
    func updateNSView(_ view: NSView,context: Context) { if let window = view.window { assign(window) } }
}
