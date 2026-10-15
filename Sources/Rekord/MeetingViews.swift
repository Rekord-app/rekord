import SwiftUI
import AppKit
import RecorderCore

/// One meeting in the list, decoded once per reload instead of on every render.
struct MeetingEntry: Identifiable {
    let url: URL
    let meeting: Meeting?
    let summary: MeetingSummary?
    var id: URL { url }
    var title: String { summary?.title ?? meeting?.displayTitle ?? url.lastPathComponent }
    var date: Date { meeting?.startedAt ?? .distantPast }
    static func load(_ urls: [URL]) -> [MeetingEntry] {
        urls.map { MeetingEntry(url: $0,meeting: try? Meeting.load(from: $0),summary: try? MeetingSummary.load(from: $0)) }
    }
}

/// Meetings workspace: recorded calls on the left (grouped by day, searchable), the selected call's key facts,
/// summary and transcript on the right.
struct MeetingsView: View {
    @ObservedObject var meetings: MeetingStore
    @State private var entries: [MeetingEntry] = []
    @State private var query = ""
    @State private var onlyWarm = false
    @State private var onlyWithNextStep = false
    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 340)
            Rectangle().fill(StudioTheme.hairline).frame(width: 1)
            Group {
                if let url = meetings.selected { MeetingDetailView(url: url,meetings: meetings).id(url) }
                else {
                    EmptyState(icon: "waveform.badge.mic",title: entries.isEmpty ? "Noch kein Meeting" : "Kein Meeting ausgewählt",
                               text: entries.isEmpty ? "Rekord erkennt Calls in Meet, Zoom, Teams und FaceTime und nimmt sie automatisch auf. Danach: Transkript, Zusammenfassung mit Interesse 1–5 und Follow-up-Entwurf." : "Wähle links einen Call. Interesse, nächster Schritt und Einwände stehen dann auf einen Blick oben.")
                }
            }
        }
        .task(id: "\(meetings.meetings.map(\.path))\(meetings.revision)") { entries = MeetingEntry.load(meetings.meetings) }
        .alert("Meeting",isPresented: Binding(get: { meetings.error != nil },set: { if !$0 { meetings.error = nil } })) {
            Button("OK") { meetings.error = nil }
            if meetings.error?.localizedCaseInsensitiveContains("Mikrofon") == true {
                Button("Datenschutz öffnen") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!); meetings.error = nil }
            }
        } message: { Text(meetings.error ?? "") }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2,pinnedViews: []) {
                if entries.isEmpty {
                    Text("Deine Calls erscheinen hier, mit Transkript, Zusammenfassung und Follow-up-Entwurf.")
                        .font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary).padding(10)
                } else if filtered.isEmpty {
                    Text("Kein Meeting passt zu Suche und Filter.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary).padding(10)
                }
                ForEach(groups,id: \.0) { group,items in
                    GroupHeader(title: group.title,count: items.count)
                    ForEach(items) { entry in MeetingRow(entry: entry,selected: meetings.selected == entry.url) { meetings.selected = entry.url }
                        .contextMenu {
                            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                            Button("Löschen …",role: .destructive) { meetings.delete(entry.url) }.disabled(meetings.phase != .idle)
                        }
                    }
                }
            }.padding(.horizontal,12).padding(.bottom,16)
        }
        .safeAreaInset(edge: .top,spacing: 0) { listHeader.padding(.horizontal,12).padding(.top,14).padding(.bottom,6) }
    }
    private var listHeader: some View {
        VStack(alignment: .leading,spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Meetings").font(StudioFont.pageTitle).foregroundStyle(StudioTheme.text)
                Spacer()
                Button { meetings.showSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 13,weight: .medium)) }
                    .buttonStyle(IconButtonStyle(size: 28,filled: false)).help("Meeting-Einstellungen").accessibilityLabel("Meeting-Einstellungen")
            }
            startCard
            if !entries.isEmpty {
                SearchField(placeholder: "Firma, Name, Titel",text: $query)
                HStack(spacing: 6) {
                    FilterChip(title: "Interesse ≥ 4",icon: "flame",isOn: $onlyWarm)
                    FilterChip(title: "Nächster Schritt",icon: "arrow.turn.down.right",isOn: $onlyWithNextStep)
                    Spacer()
                }
            }
        }
        .padding(12).glassBar()
    }
    @ViewBuilder private var startCard: some View {
        switch meetings.phase {
        case .idle:
            VStack(alignment: .leading,spacing: 8) {
                Button { meetings.requestStart() } label: {
                    HStack(spacing: 8) { Image(systemName: "waveform").font(.system(size: 12,weight: .bold)); Text("Meeting aufnehmen"); Spacer(); Text("⌃⌥⌘M").font(StudioFont.shortcut).opacity(0.75) }
                }.buttonStyle(AccentButtonStyle(height: 36)).frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    Image(systemName: meetings.autoRecord ? "bolt.fill" : "bolt.slash").font(.system(size: 9,weight: .bold))
                    Text(meetings.autoRecord ? "Calls werden automatisch aufgenommen" : "Automatische Aufnahme aus")
                }.font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
                if !meetings.hasAPIKey {
                    Button { meetings.showSettings = true } label: {
                        Label("Ohne Claude-Schlüssel: Audio und lokale Transkription",systemImage: "key").font(StudioFont.caption).foregroundStyle(StudioTheme.warning)
                    }.buttonStyle(.plain)
                }
            }
        case .starting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Aufnahme startet …").font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary) }.frame(height: 36)
        case .recording:
            HStack(spacing: 10) {
                Circle().fill(StudioTheme.accent).frame(width: 8,height: 8).shadow(color: StudioTheme.accent.opacity(0.8),radius: 4)
                Text(recordingClock(meetings.elapsed)).font(.system(size: 18,weight: .semibold,design: .rounded)).monospacedDigit().foregroundStyle(StudioTheme.text)
                if let app = meetings.callApp { Text(app).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).lineLimit(1) }
                Spacer()
                Button("Stoppen") { meetings.stop() }.buttonStyle(AccentButtonStyle(height: 30))
            }
        case .processing:
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(meetings.progress.isEmpty ? "Wird verarbeitet …" : meetings.progress).font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary).lineLimit(2) }
        }
    }
    private var filtered: [MeetingEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            if onlyWarm, (entry.summary?.interest ?? 0) < 4 { return false }
            if onlyWithNextStep, (entry.summary?.nextStep.action.isEmpty ?? true) && (entry.summary?.actionItems.isEmpty ?? true) { return false }
            guard !needle.isEmpty else { return true }
            let haystack = [entry.title,entry.meeting?.company ?? "",entry.meeting?.contact ?? "",entry.meeting?.app ?? "",entry.summary?.shortSummary ?? "",entry.summary?.purpose ?? "",entry.summary?.callTypeLabel ?? ""].joined(separator: " ").lowercased()
            return haystack.contains(needle)
        }
    }
    private var groups: [(RelativeDay.Group,[MeetingEntry])] {
        let grouped = Dictionary(grouping: filtered) { RelativeDay.group($0.date) }
        return RelativeDay.Group.allCases.compactMap { group in grouped[group].map { (group,$0.sorted { $0.date > $1.date }) } }
    }
}

private struct MeetingRow: View {
    let entry: MeetingEntry
    let selected: Bool
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            HStack(alignment: .top,spacing: 10) {
                VStack(alignment: .leading,spacing: 3) {
                    Text(entry.title).font(.system(size: 13,weight: .semibold)).foregroundStyle(StudioTheme.text).lineLimit(1)
                    Text(subtitle).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                    if let line = entry.summary.map({ $0.purpose ?? $0.shortSummary }), !line.isEmpty {
                        Text(line).font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary).lineLimit(2).fixedSize(horizontal: false,vertical: true)
                    }
                    if let summary = entry.summary, summary.isSales, !summary.nextStep.action.isEmpty {
                        let step = summary.nextStep
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 8,weight: .bold))
                            Text([step.action,step.date].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1)
                        }.font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
                    }
                }
                Spacer(minLength: 4)
                trailing
            }.padding(.horizontal,10).padding(.vertical,9).frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).listRow(selected: selected)
        .accessibilityLabel("\(entry.title), \(subtitle)")
    }
    @ViewBuilder private var trailing: some View {
        if let summary = entry.summary, summary.isSales { InterestBadge(value: summary.interest) }
        else if let summary = entry.summary { Image(systemName: summary.callType == "private" ? "cup.and.saucer" : summary.callType == "internal" ? "building.2" : "bubble.left.and.bubble.right")
            .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary).help(summary.callTypeLabel) }
        else if let meeting = entry.meeting, meeting.status == .failed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StudioTheme.warning).help(meeting.error ?? "Verarbeitung fehlgeschlagen") }
        else if let meeting = entry.meeting, meeting.status != .done { ProgressView().controlSize(.mini).help("Wird verarbeitet") }
    }
    private var subtitle: String {
        guard let meeting = entry.meeting else { return "" }
        var parts = [RelativeDay.label(meeting.startedAt),minutes(meeting.duration)]
        if let app = meeting.app { parts.append(app) }
        return parts.joined(separator: " · ")
    }
}

/// „31 min“ for list rows, exact mm:ss stays in the detail header.
func minutes(_ seconds: Double) -> String {
    let m = Int((max(0,seconds)/60).rounded())
    return m < 1 ? "unter 1 min" : "\(m) min"
}

struct InterestBadge: View {
    let value: Int
    var large = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5,id: \.self) { i in
                Circle().fill(i < value ? color : StudioTheme.hairlineStrong).frame(width: large ? 7 : 5,height: large ? 7 : 5)
            }
            Text("\(value)").font(.system(size: large ? 13 : 11,weight: .bold,design: .rounded)).foregroundStyle(color).padding(.leading,3).monospacedDigit()
        }
        .padding(.horizontal,8).padding(.vertical,large ? 6 : 4)
        .background(color.opacity(0.14),in: Capsule())
        .help("Interesse \(value) von 5").accessibilityLabel("Interesse \(value) von 5")
    }
    private var color: Color { value >= 4 ? StudioTheme.success : value == 3 ? StudioTheme.warning : StudioTheme.textSecondary }
}

/// All settings in one sheet: meetings, Claude, sharing. Opened from the sidebar gear and the Meetings header.
struct SettingsSheet: View {
    @ObservedObject var meetings: MeetingStore
    @EnvironmentObject var store: EditorStore
    @State private var key = ""
    var body: some View {
        VStack(alignment: .leading,spacing: 0) {
            HStack {
                VStack(alignment: .leading,spacing: 2) {
                    Text("Einstellungen").font(StudioFont.pageTitle)
                    Text("Gelten für diesen Mac-Benutzer.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                Button("Fertig") { if !key.isEmpty { meetings.saveAPIKey(key) }; meetings.showSettings = false }.buttonStyle(PillButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }.padding(.horizontal,24).padding(.top,20).padding(.bottom,14)
            Form {
                Section("Meetings") {
                    Text("Aufnahme ab macOS 14.2 · lokale Transkription ab macOS 26. Ohne Claude-Schlüssel bleiben Audio und Transkript nutzbar. Automatische Aufnahme ist standardmäßig aus und muss nach dem Sicherheitsupdate neu bestätigt werden.").font(.caption)
                    TextField("Dein Name im Transkript",text: $meetings.ownName)
                    TextField("Begriffe, die oft fallen (Komma-getrennt)",text: $meetings.glossary,axis: .vertical).lineLimit(2...4)
                    Toggle("Calls automatisch aufnehmen (Meet, Zoom, Teams, FaceTime, Slack …)",isOn: Binding(get: { meetings.autoRecord },set: { meetings.setAutoRecord($0) }))
                    Toggle("Zeit und Pegel während Meetings anzeigen (sonst nur ein kleiner roter Punkt)",isOn: $meetings.showController)
                    Toggle("Rekord beim Anmelden starten",isOn: Binding(get: { meetings.launchAtLogin },set: { meetings.setLaunchAtLogin($0) }))
                }
                Section {
                    SecureField(meetings.hasAPIKey ? "Claude-API-Schlüssel (gespeichert)" : "Claude-API-Schlüssel (sk-ant-…)",text: $key)
                    if meetings.hasAPIKey { Button("Schlüssel entfernen",role: .destructive) { meetings.saveAPIKey("") } }
                } header: { Text("Claude") } footer: {
                    Text("Liegt im Schlüsselbund dieses Benutzers. Ohne Schlüssel entstehen nur Transkripte und Vorlagen-Texte; Begriffe aus der Liste helfen, verhörte Firmen- und Produktnamen zu korrigieren.")
                }
                Section {
                    HStack {
                        Label(store.shareConfigured ? "Share-Server eingerichtet" : "Noch kein Share-Server",systemImage: store.shareConfigured ? "checkmark.shield" : "link")
                        Spacer()
                        Button(store.shareConfigured ? "Verwalten …" : "Einrichten …") { meetings.showSettings = false; store.showShareSettings = true }
                    }
                    ShareExpiryPicker()
                } header: { Text("Teilen") } footer: {
                    Text("Links für Aufnahmen und Anleitungen laufen über deinen eigenen Server. Ohne Server bleibt alles lokal. Abgelaufene Links geben ihren Platz auf dem Server frei; einzelne Links behältst du dauerhaft unter „Freigaben verwalten“ → Behalten.")
                }
                StorageSettingsSection()
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }.frame(width: 580,height: 680).background(StudioTheme.background)
    }
}

/// Floating timer, level meters and Stop while a meeting records (never part of any screen recording).
@MainActor final class MeetingPanelController {
    private var panel: NSPanel?
    private static let full = CGSize(width: 280,height: 118), dot = CGSize(width: 34,height: 34)
    /// `compact`: only a small red dot (no timer, no meters); click it to expand. Keeps the top-right corner.
    func show(store: MeetingStore,compact: Bool) {
        let size = compact ? Self.dot : Self.full
        if panel == nil {
            let next = NSPanel(contentRect: CGRect(origin: .zero,size: size),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
            next.isReleasedWhenClosed = false; next.isOpaque = false; next.backgroundColor = .clear
            next.level = .floating; next.hidesOnDeactivate = false; next.hasShadow = true; next.isMovableByWindowBackground = true
            next.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; next.sharingType = .none
            next.setAccessibilityLabel("Meeting-Controller")
            next.contentView = NSHostingView(rootView: MeetingControllerView(meetings: store))
            let area = NSScreen.main?.visibleFrame ?? CGRect(x: 0,y: 0,width: 1440,height: 900)
            next.setFrameOrigin(CGPoint(x: area.maxX-24-size.width,y: area.maxY-24-size.height))
            panel = next
        } else if let panel, panel.frame.size != size {
            let frame = panel.frame
            panel.setFrame(CGRect(x: frame.maxX-size.width,y: frame.maxY-size.height,width: size.width,height: size.height),display: true,animate: true)
        }
        panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil); panel = nil }
}

struct MeetingControllerView: View {
    @ObservedObject var meetings: MeetingStore
    @State private var pulse = false
    var body: some View {
        if meetings.controllerCompact { dot } else { full }
    }
    /// Unobtrusive: a small pulsing red dot, nothing else. Click to show the full controller.
    private var dot: some View {
        Button { meetings.expandController() } label: {
            Circle().fill(StudioTheme.accent).frame(width: 12,height: 12).scaleEffect(pulse ? 1 : 0.75).opacity(pulse ? 1 : 0.6)
                .frame(width: 34,height: 34).background(Color.black.opacity(0.55),in: Circle()).contentShape(Circle())
        }.buttonStyle(.plain).help("Rekord nimmt auf · klicken zum Einblenden").accessibilityLabel("Meeting-Aufnahme läuft, Controller einblenden")
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true } }
    }
    private var full: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(StudioTheme.accent).frame(width: 7,height: 7).shadow(color: StudioTheme.accent.opacity(0.8),radius: 4)
                Text(recordingClock(meetings.elapsed)).font(.system(size: 20,weight: .semibold,design: .rounded)).monospacedDigit().foregroundStyle(.white)
                Spacer()
                Text(meetings.callApp ?? "Meeting").font(.system(size: 11,weight: .semibold)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                Button { meetings.collapseController() } label: { Image(systemName: "eye.slash").font(.system(size: 11,weight: .medium)).foregroundStyle(.white.opacity(0.75)).frame(width: 24,height: 24).background(Color.white.opacity(0.1),in: Circle()) }
                    .buttonStyle(.plain).help("Ausblenden: nur noch ein kleiner roter Punkt, Aufnahme läuft weiter").accessibilityLabel("Controller ausblenden")
                Button { meetings.discard() } label: { Image(systemName: "trash").font(.system(size: 11,weight: .medium)).foregroundStyle(.white.opacity(0.75)).frame(width: 24,height: 24).background(Color.white.opacity(0.1),in: Circle()) }
                    .buttonStyle(.plain).help("Verwerfen: nichts speichern und diesen Call nicht mehr aufnehmen").accessibilityLabel("Aufnahme verwerfen")
            }
            meter("Ich",meetings.microphoneLevel)
            meter("Gegenüber",meetings.systemLevel)
            Button { meetings.stop() } label: {
                HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 10,height: 10); Text("Stoppen"); Text("⌃⌥⌘M").font(StudioFont.shortcut).opacity(0.7) }
                    .font(.system(size: 13,weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 32).background(StudioTheme.accentGradient,in: Capsule())
            }.buttonStyle(.plain).accessibilityLabel("Meeting stoppen")
        }.padding(14).modifier(GlassPanel(cornerRadius: 22,tint: .black.opacity(0.45))).environment(\.colorScheme,.dark)
    }
    private func meter(_ title: String,_ level: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10,weight: .medium)).foregroundStyle(.white.opacity(0.7)).frame(width: 62,alignment: .leading)
            AudioMeter(level: level).frame(height: 10)
        }
    }
}
