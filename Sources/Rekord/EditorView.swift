import SwiftUI
import RecorderCore

struct EditorView: View {
    @EnvironmentObject var store: EditorStore
    @State private var audiencePresented = false
    var body: some View {
        HStack(spacing: 0) {
            if store.workspace != .edit {
                Sidebar(meetings: store.meetings).frame(width: 224)
                Rectangle().fill(StudioTheme.hairline).frame(width: 1)
            }
            VStack(spacing: 0) {
                if store.workspace == .record {
                    HomeView()
                } else if store.workspace == .meetings {
                    MeetingsView(meetings: store.meetings)
                } else if store.workspace == .guides {
                    GuidesView(guides: store.guides)
                } else {
                    EditorTopBar(audiencePresented: $audiencePresented)
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            preview
                            TransportBar()
                            if let p = store.project { EditorTimeline(project: p).padding(.horizontal,18).padding(.bottom,14).disabled(store.busy) }
                        }
                        Rectangle().fill(StudioTheme.hairline).frame(width: 1)
                        InspectorView().frame(width: 304).disabled(store.busy)
                    }
                }
                statusBar
            }
        }
        .background(StudioTheme.background).tint(StudioTheme.accent)
        .background(WindowAccessor { window in if store.mainWindow !== window { store.mainWindow = window } })
        .sheet(isPresented: $store.showShareSettings) { ShareSettingsView().environmentObject(store) }
        .sheet(isPresented: $audiencePresented) { AudienceView().environmentObject(store) }
        .onChange(of: store.selectedSource) { store.updateMonitor() }
        .onChange(of: store.withCamera) { store.updateMonitor() }
        .onChange(of: store.withMicrophone) { store.updateMonitor() }
        .onChange(of: store.recordingStyle) { store.updateMonitor() }
        .alert("Rekord",isPresented: Binding(get: { store.error != nil },set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
            if let error = store.error,error.contains("zugriff") || error.contains("freigeben") || error.contains("Bildschirmzugriff") {
                Button("Datenschutz öffnen") {
                    let pane = error.localizedCaseInsensitiveContains("Mikrofon") ? "Privacy_Microphone" : (error.localizedCaseInsensitiveContains("Kamera") ? "Privacy_Camera" : "Privacy_ScreenCapture")
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    store.error = nil
                }
            }
        } message: { Text(store.error ?? "") }
    }
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(store.phase == .recording ? StudioTheme.accent : StudioTheme.textTertiary.opacity(0.6)).frame(width: 5,height: 5)
            Text(store.status).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
            if store.phase == .recording { Text(recordingClock(store.elapsed)).font(StudioFont.captionStrong).monospacedDigit().foregroundStyle(StudioTheme.accent) }
            Spacer()
            ExportStatusIndicator(queue: store.exports) { if store.project != nil { store.showEditor(); store.inspectorTab = .export } }
            if store.workspace == .edit,store.project != nil { Label("Originale bleiben erhalten",systemImage: "checkmark.circle").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary) }
        }.padding(.horizontal,StudioTheme.gutter).frame(height: 28)
        .background(StudioTheme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(StudioTheme.hairline).frame(height: 1) }
    }
    private var preview: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: StudioTheme.radiusLarge,style: .continuous).fill(Color.black.opacity(0.32))
                    .overlay(RoundedRectangle(cornerRadius: StudioTheme.radiusLarge,style: .continuous).strokeBorder(StudioTheme.hairline))
                PlayerSurface(player: store.player).padding(16).shadow(color: .black.opacity(0.45),radius: 20,y: 10).opacity(store.playerReady ? 1 : 0)
                if !store.playerReady { ProgressView("Vorschau wird geladen …").foregroundStyle(StudioTheme.textSecondary) }
                if let image = store.removedFrame { RemovedFrameView(image: image).padding(12) }
                if store.phase == .exporting || store.phase == .uploading {
                    VStack(spacing: 14) {
                        Text(store.phase == .uploading ? "Dein Video wird hochgeladen" : "Dein Video wird vorbereitet").font(StudioFont.title)
                        ProgressView(value: store.exportProgress).frame(width: 250)
                        Text("\(Int(store.exportProgress*100)) %").font(.caption.monospacedDigit()).foregroundStyle(StudioTheme.textSecondary)
                        Button("Abbrechen") { store.cancelExport() }.buttonStyle(.pill)
                    }.padding(30).modifier(GlassPanel(cornerRadius: 18,tint: .black.opacity(0.3)))
                }
            }.frame(maxHeight: .infinity)
            if let receipt = store.shareReceipt {
                HStack(spacing: 10) {
                    Label("Link bereit",systemImage: "checkmark.circle.fill").foregroundStyle(StudioTheme.success).font(StudioFont.captionStrong)
                    Text(receipt.video.url.absoluteString).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let date = receipt.video.expiryDate {
                        Text("läuft ab am \(date.formatted(date: .numeric,time: .omitted))").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary).fixedSize()
                            .help("Ändern unter Teilen → Freigaben verwalten (Behalten)")
                    }
                    Spacer()
                    Button("Link kopieren") { store.copyShareLink() }.buttonStyle(.pill)
                    Button("Öffnen") { store.openShareLink() }.buttonStyle(.pill)
                    Menu { Button("Link deaktivieren",role: .destructive) { store.revokeShare() } } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("Weitere Optionen zum Link")
                }
                .padding(.horizontal,12).padding(.vertical,8).studioInset()
                .help("Der Link zeigt die zuletzt geteilte Fassung. Nach Änderungen erneut teilen.")
            }
        }.padding(.horizontal,18).padding(.top,14)
    }
}

/// Navigation: wordmark, the one primary action, the four areas and the latest recordings.
private struct Sidebar: View {
    @EnvironmentObject var store: EditorStore
    @ObservedObject var meetings: MeetingStore
    var body: some View {
        VStack(alignment: .leading,spacing: 0) {
            // Wordmark: the record dot from the app icon followed by the name.
            HStack(spacing: 9) {
                Circle().fill(RadialGradient(colors: [Color(red: 1,green: 0.5,blue: 0.48),Color(red: 0.95,green: 0.12,blue: 0.18),Color(red: 0.55,green: 0.02,blue: 0.08)],center: UnitPoint(x: 0.35,y: 0.3),startRadius: 0,endRadius: 12))
                    .frame(width: 18,height: 18).shadow(color: StudioTheme.accent.opacity(0.55),radius: 6)
                Text("rekord").font(.system(size: 20,weight: .heavy)).tracking(-0.7).foregroundStyle(StudioTheme.text)
            }.padding(.horizontal,8).padding(.top,14).padding(.bottom,18).accessibilityElement(children: .combine).accessibilityLabel("Rekord")
            Button { store.openRecorder() } label: {
                HStack(spacing: 8) { RecordDot(); Text("Neue Aufnahme").lineLimit(1); Spacer(minLength: 0) }
            }.buttonStyle(AccentButtonStyle(height: 38)).disabled(store.busy).padding(.bottom,18).help("Neue Aufnahme · ⌘⇧1")
            VStack(spacing: 2) {
                nav("Aufnahmen",icon: "rectangle.stack",selected: store.workspace == .record,count: store.recent.count) { store.showRecordingSetup() }
                nav("Meetings",icon: "waveform.badge.mic",selected: store.workspace == .meetings,count: meetings.meetings.count) { store.showMeetings() }
                nav("Anleitungen",icon: "list.number",selected: store.workspace == .guides,count: store.guides.guides.count) { store.showGuides() }
            }
            if store.project != nil {
                VStack(alignment: .leading,spacing: 6) {
                    Text("Geöffnet").eyebrow().padding(.horizontal,8)
                    nav(store.displayName,icon: "slider.horizontal.3",selected: store.workspace == .edit,count: nil) { store.showEditor() }.disabled(store.busy)
                }.padding(.top,18)
            }
            VStack(alignment: .leading,spacing: 6) {
                HStack {
                    Text("Zuletzt").eyebrow()
                    Spacer()
                    Button { store.openProject() } label: { Image(systemName: "folder.badge.plus").font(.system(size: 12,weight: .medium)) }
                        .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary).help("Projekt öffnen · ⌘O").accessibilityLabel("Projekt öffnen").disabled(store.busy)
                }.padding(.horizontal,8)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(store.recent.prefix(8),id: \.self) { url in RecentRow(url: url) }
                        if store.recent.isEmpty { Text("Deine Videos erscheinen hier nach der ersten Aufnahme.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary).frame(maxWidth: .infinity,alignment: .leading).padding(8) }
                    }
                }
            }.padding(.top,22).frame(maxHeight: .infinity,alignment: .top)
            Rectangle().fill(StudioTheme.hairline).frame(height: 1).padding(.vertical,10)
            HStack(spacing: 8) {
                Button { store.showShareSettings = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: store.shareConfigured ? "checkmark.shield" : "link").font(.system(size: 11,weight: .medium))
                        Text(store.shareConfigured ? "Teilen eingerichtet" : "Teilen einrichten").font(StudioFont.caption).lineLimit(1)
                    }.foregroundStyle(StudioTheme.textSecondary).padding(.horizontal,8).frame(height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(store.busy).help("Share-Server verwalten")
                Spacer()
                Button { meetings.showSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 13,weight: .medium)) }
                    .buttonStyle(IconButtonStyle(size: 30,filled: false)).help("Einstellungen").accessibilityLabel("Einstellungen").disabled(store.busy)
            }
        }.padding(.horizontal,12).padding(.bottom,12).background(StudioTheme.sidebar)
        .sheet(isPresented: $meetings.showSettings) { SettingsSheet(meetings: meetings).environmentObject(store) }
    }
    private func nav(_ title: String,icon: String,selected: Bool,count: Int?,action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13,weight: .medium)).frame(width: 18).foregroundStyle(selected ? StudioTheme.accent : StudioTheme.textSecondary)
                Text(title).font(.system(size: 13,weight: selected ? .semibold : .medium)).foregroundStyle(selected ? StudioTheme.text : StudioTheme.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                if let count, count > 0 { Text("\(count)").font(StudioFont.shortcut).foregroundStyle(StudioTheme.textTertiary).monospacedDigit() }
            }
            .padding(.horizontal,10).frame(height: 34)
            .background(selected ? StudioTheme.fillHover : .clear,in: RoundedRectangle(cornerRadius: StudioTheme.radiusSmall+1,style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.radiusSmall+1,style: .continuous))
        }.buttonStyle(.plain).disabled(store.busy).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// One recent recording in the sidebar: title and relative time, highlighted while open in the editor.
private struct RecentRow: View {
    @EnvironmentObject var store: EditorStore
    let url: URL
    @State private var title = ""
    var body: some View {
        let open = store.directory == url
        Button { store.open(url) } label: {
            HStack(spacing: 9) {
                Image(systemName: open ? "play.rectangle.fill" : "play.rectangle").font(.system(size: 12)).foregroundStyle(open ? StudioTheme.accent : StudioTheme.textTertiary).frame(width: 18)
                VStack(alignment: .leading,spacing: 1) {
                    Text(open ? RecordingInfo.displayTitle(store.project,url) : title)
                        .font(.system(size: 12,weight: .medium)).foregroundStyle(open ? StudioTheme.text : StudioTheme.textSecondary).lineLimit(1)
                    if let date = RecordingInfo.date(url) { Text(RelativeDay.label(date)).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }.padding(.horizontal,8).padding(.vertical,6)
        }.buttonStyle(.plain).listRow(selected: open && store.workspace == .edit).disabled(store.busy)
        .task(id: url) { title = RecordingInfo.title(url); if let project = try? Project.load(from: url) { title = RecordingInfo.displayTitle(project,url) } }
        .contextMenu { Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    }
}

/// Title and date of a recording folder without loading the whole project.
enum RecordingInfo {
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH-mm-ss"; return f }()
    /// Date from the folder name („Aufnahme 2026-10-15 11-15-00“), else the folder's creation date.
    static func date(_ url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("Aufnahme "), let date = stamp.date(from: String(name.dropFirst(9).prefix(19))) { return date }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }
    /// Custom title from the folder name; dated recordings read „Aufnahme“ (the date stands next to it).
    static func title(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.hasPrefix("Aufnahme ") ? "Aufnahme" : name
    }
    /// A project's own name, or „Studio-Aufnahme“ / „Loom-Aufnahme“ for recordings that were never renamed.
    static func displayTitle(_ project: Project?,_ url: URL) -> String {
        guard let project else { return title(url) }
        if !project.name.isEmpty, !project.name.hasPrefix("Aufnahme ") { return project.name }
        return project.recordingMode == .loom ? "Loom-Aufnahme" : "Studio-Aufnahme"
    }
}

struct PlaybackControls: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        HStack(spacing: 12) {
            Button { store.seekEdited(0) } label: { Image(systemName: "backward.end.fill") }.help("Zum Anfang").accessibilityLabel("Zum Anfang")
            Button { store.togglePlayback() } label: { Image(systemName: store.playing ? "pause.fill" : "play.fill").frame(width: 18) }.help("Abspielen / Pause · Leertaste").accessibilityLabel(store.playing ? "Pause" : "Abspielen")
            if let p = store.project {
                Slider(value: Binding(get: { store.editedTime },set: { store.seekEdited($0) }),in: 0...max(0.01,p.editedDuration)).accessibilityLabel("Schnittvorschau")
                Text("\(clock(store.editedTime)) / \(clock(p.editedDuration))").font(.system(size: 11,design: .monospaced)).foregroundStyle(StudioTheme.textSecondary)
            }
        }.buttonStyle(.plain).disabled(store.project == nil || store.busy)
    }
}

private struct AudienceView: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                VStack(alignment: .leading,spacing: 3) {
                    Text("So sehen Zuschauer dein Video").font(StudioFont.title)
                    Text("Mit deinem Bildaufbau, Schnitt, Zoom und Ton.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                Button("Fertig") { store.pause(); dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
            }
            ZStack {
                PlayerSurface(player: store.player).frame(maxWidth: .infinity,maxHeight: .infinity)
                if let image = store.removedFrame { RemovedFrameView(image: image) }
            }
            PlaybackControls()
        }.padding(24).frame(width: 900,height: 620).background(StudioTheme.background)
            .onDisappear { store.pause() }
    }
}

/// The playhead is in a range that was cut out: show the original frame, clearly marked as not in the video.
private struct RemovedFrameView: View {
    let image: CGImage
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.55)
            Image(decorative: image,scale: 1).resizable().aspectRatio(contentMode: .fit).opacity(0.45)
            Label("Herausgeschnitten · nicht im Video",systemImage: "scissors").font(.system(size: 12,weight: .semibold))
                .padding(.horizontal,12).padding(.vertical,7).modifier(GlassPanel(cornerRadius: 20,tint: .black.opacity(0.3))).padding(.top,14)
        }.clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

func label(_ title: String) -> some View { Text(title).eyebrow() }
func clock(_ time: Double) -> String { let t = max(0,time.isFinite ? time : 0); return String(format: "%02d:%02d.%01d",Int(t)/60,Int(t)%60,Int(t*10)%10) }
