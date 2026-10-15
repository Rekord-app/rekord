import SwiftUI
import AppKit
import RecorderCore

/// One guide in the list, decoded once per reload.
struct GuideEntry: Identifiable {
    let url: URL
    let guide: Guide?
    let hasBrief: Bool
    let shared: Bool
    var id: URL { url }
    var title: String { guide?.title ?? url.lastPathComponent }
    var date: Date { guide?.createdAt ?? .distantPast }
    static func load(_ urls: [URL]) -> [GuideEntry] {
        urls.map { url in
            GuideEntry(url: url,guide: try? Guide.load(from: url),
                       hasBrief: FileManager.default.fileExists(atPath: url.appendingPathComponent(GuideFile.brief).path),
                       shared: GuideSharing.record(in: url) != nil)
        }
    }
}

/// Guides workspace: recorded flows on the left (grouped by day, searchable), the selected guide as an editable
/// step list on the right.
struct GuidesView: View {
    @ObservedObject var guides: GuideStore
    @State private var entries: [GuideEntry] = []
    @State private var query = ""
    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 340)
            Rectangle().fill(StudioTheme.hairline).frame(width: 1)
            Group {
                if let url = guides.selected { GuideDetailView(url: url,guides: guides).id(url) }
                else {
                    EmptyState(icon: "list.number",title: entries.isEmpty ? "Noch keine Anleitung" : "Keine Anleitung ausgewählt",
                               text: entries.isEmpty ? "Nimm einen Ablauf auf und erkläre dabei laut, was du tust. Rekord macht daraus eine Anleitung mit Bildern, ein PDF und eine Einschätzung, was sich automatisieren lässt." : "Wähle links eine Anleitung. Titel, Texte und Bilder lassen sich direkt bearbeiten.")
                }
            }
        }
        .task(id: "\(guides.guides.map(\.path))\(guides.revision)") { entries = GuideEntry.load(guides.guides) }
        .alert("Anleitung",isPresented: Binding(get: { guides.error != nil },set: { if !$0 { guides.error = nil } })) {
            Button("OK") { guides.error = nil }
            if guides.error?.localizedCaseInsensitiveContains("Bedienungshilfen") == true {
                Button("Bedienungshilfen öffnen") { GuideSettingsLink.openAccessibility(); guides.error = nil }
            }
        } message: { Text(guides.error ?? "") }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if entries.isEmpty {
                    Text("Deine Anleitungen erscheinen hier: ein Schritt pro Klick, mit Screenshot und Text.")
                        .font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary).padding(10)
                } else if filtered.isEmpty {
                    Text("Keine Anleitung passt zur Suche.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary).padding(10)
                }
                ForEach(groups,id: \.0) { group,items in
                    GroupHeader(title: group.title,count: items.count)
                    ForEach(items) { entry in
                        GuideRow(entry: entry,selected: guides.selected == entry.url) { guides.selected = entry.url }
                            .contextMenu {
                                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                                Button("Löschen …",role: .destructive) { guides.delete(entry.url) }.disabled(guides.phase != .idle)
                            }
                    }
                }
            }.padding(.horizontal,12).padding(.bottom,16)
        }
        .safeAreaInset(edge: .top,spacing: 0) { listHeader.padding(.horizontal,12).padding(.top,14).padding(.bottom,6) }
    }
    private var listHeader: some View {
        VStack(alignment: .leading,spacing: 10) {
            Text("Abläufe dokumentieren").font(StudioFont.pageTitle).foregroundStyle(StudioTheme.text)
            startCard
            if !entries.isEmpty { SearchField(placeholder: "Titel oder App",text: $query) }
        }
        .padding(12).glassBar()
    }
    @ViewBuilder private var startCard: some View {
        switch guides.phase {
        case .idle:
            VStack(alignment: .leading,spacing: 8) {
                Button { guides.start() } label: {
                    HStack(spacing: 8) { Image(systemName: "list.number").font(.system(size: 12,weight: .bold)); Text("Anleitung aufnehmen"); Spacer() }
                }.buttonStyle(AccentButtonStyle(height: 36)).frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    Text("Anrede").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
                    Segmented(options: GuideAddress.allCases.map { ($0,$0.label) },selection: $guides.address).frame(width: 96).help("Anrede in den Schritt-Texten")
                    Spacer()
                    Text("Bildschirm + Mikro").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
                }
                if !GuideAccessibility.trusted && !SnapshotDiagnostics.active {
                    Button { GuideAccessibility.requestTrust(); GuideSettingsLink.openAccessibility() } label: {
                        Label("Bedienungshilfen erlauben, sonst fehlen die Namen der Knöpfe",systemImage: "hand.raised").font(StudioFont.caption).foregroundStyle(StudioTheme.warning)
                    }.buttonStyle(.plain)
                }
            }
        case .starting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Aufnahme startet …").font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary) }.frame(height: 36)
        case .recording:
            HStack(spacing: 10) {
                Circle().fill(StudioTheme.accent).frame(width: 8,height: 8).shadow(color: StudioTheme.accent.opacity(0.8),radius: 4)
                Text(recordingClock(guides.elapsed)).font(.system(size: 18,weight: .semibold,design: .rounded)).monospacedDigit().foregroundStyle(StudioTheme.text)
                Text("\(guides.clicks) Klicks").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Button("Fertig") { guides.stop() }.buttonStyle(AccentButtonStyle(height: 30))
            }
        case .processing:
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(guides.progress.isEmpty ? "Wird verarbeitet …" : guides.progress).font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary).lineLimit(2) }
        }
    }
    private var filtered: [GuideEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { ([$0.title]+($0.guide?.apps ?? [])).joined(separator: " ").lowercased().contains(needle) }
    }
    private var groups: [(RelativeDay.Group,[GuideEntry])] {
        let grouped = Dictionary(grouping: filtered) { RelativeDay.group($0.date) }
        return RelativeDay.Group.allCases.compactMap { group in grouped[group].map { (group,$0.sorted { $0.date > $1.date }) } }
    }
}

enum GuideSettingsLink {
    static func openAccessibility() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
}

private struct GuideRow: View {
    let entry: GuideEntry
    let selected: Bool
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            HStack(alignment: .top,spacing: 10) {
                VStack(alignment: .leading,spacing: 3) {
                    Text(entry.title).font(.system(size: 13,weight: .semibold)).foregroundStyle(StudioTheme.text).lineLimit(1)
                    Text(subtitle).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    if entry.hasBrief { StatusBadge(text: "Brief",tone: .info,icon: "bolt") }
                    if entry.shared { StatusBadge(text: "Geteilt",tone: .success,icon: "link") }
                    if entry.guide == nil { ProgressView().controlSize(.mini) }
                }
            }.padding(.horizontal,10).padding(.vertical,9).frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).listRow(selected: selected)
        .accessibilityLabel("\(entry.title), \(subtitle)")
    }
    private var subtitle: String {
        guard let guide = entry.guide else { return "wird verarbeitet …" }
        var parts = [RelativeDay.label(guide.createdAt),"\(guide.steps.count) Schritte"]
        if let app = guide.apps.first { parts.append(app) }
        return parts.joined(separator: " · ")
    }
}

struct GuideDetailView: View {
    let url: URL
    @ObservedObject var guides: GuideStore
    @State private var guide: Guide?
    @State private var brief: AutomationBrief?
    @State private var redacting: Int?
    @State private var pendingSave: Task<Void,Never>?
    @State private var edited = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 16) {
                if let notice = guides.notice {
                    HStack(alignment: .top,spacing: 10) {
                        Label(notice,systemImage: "info.circle").font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary).textSelection(.enabled)
                        Spacer(); Button { guides.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle(size: 24,filled: false)).accessibilityLabel("Hinweis schließen")
                    }.studioInset()
                }
                if guides.phase == .processing {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(guides.progress).font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary) }
                }
                if let guide {
                    if let inventory = guides.inventory { GuideProcessPlanning(guide: guide,url: url,inventory: inventory,guides: guides) }
                    automation(guide)
                    HStack(spacing: 6) { Image(systemName: "list.number").font(.system(size: 10,weight: .semibold)).foregroundStyle(StudioTheme.textTertiary); Text("\(guide.steps.count) Schritte").eyebrow() }.padding(.top,8)
                    ForEach(Array(guide.steps.enumerated()),id: \.element.id) { index,step in stepCard(index,step,count: guide.steps.count) }
                    if guide.steps.isEmpty { Text("Keine Schritte erkannt.").font(StudioFont.body).foregroundStyle(StudioTheme.textTertiary) }
                }
            }.padding(StudioTheme.gutter).padding(.top,4).frame(maxWidth: 900,alignment: .leading).frame(maxWidth: .infinity,alignment: .leading)
        }
        .safeAreaInset(edge: .top,spacing: 0) { header.padding(.horizontal,StudioTheme.gutter).padding(.top,14).padding(.bottom,6) }
        .task(id: guides.revision) { if !edited { load() } }
        .onDisappear { pendingSave?.cancel(); if edited,let guide { guides.save(guide,at: url) } }
        .sheet(item: Binding(get: { redacting.map { RedactTarget(index: $0) } },set: { redacting = $0?.index })) { target in
            if let guide { RedactSheet(url: url,guide: guide,index: target.index) { updated in self.guide = updated; guides.save(updated,at: url,regenerateImages: true); redacting = nil } }
        }
    }
    private func queueSave() {
        edited = true; pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let guide else { return }; edited = false; guides.save(guide,at: url)
        }
    }
    private func load() {
        guide = guides.load(url); brief = try? AutomationBrief.load(from: url)
    }
    private func update(images: Bool = false,_ change: (inout Guide) -> Void) {
        pendingSave?.cancel(); edited = false
        guard var current = guide else { return }
        change(&current); guide = current
        guides.save(current,at: url,regenerateImages: images)
    }
    /// Pinned: editable title, meta, link, the three outputs and the menu.
    private var header: some View {
        HStack(alignment: .top,spacing: 12) {
            VStack(alignment: .leading,spacing: 3) {
                TextField("Titel",text: Binding(get: { guide?.title ?? "" },set: { value in guide?.title = value; queueSave() }),onCommit: { update { _ in } })
                    .textFieldStyle(.plain).font(StudioFont.pageTitle).foregroundStyle(StudioTheme.text).accessibilityLabel("Titel der Anleitung")
                if let guide {
                    HStack(spacing: 8) {
                        Text([guide.apps.joined(separator: ", "),"\(guide.steps.count) Schritte","Video \(timestamp(guide.duration))",guide.textsBy == "template" ? "Vorlagen-Texte" : "Texte von Claude"].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                        if let shared = GuideSharing.record(in: url) {
                            Link(destination: shared.url) { StatusBadge(text: "Geteilt · Link öffnen",tone: .success,icon: "link") }.help(shared.url.absoluteString)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button { guides.share(url) } label: { Label("Teilen",systemImage: "link").fixedSize() }.buttonStyle(PillButtonStyle(prominent: true)).help("Als mobile Seite auf deinem Share-Server veröffentlichen")
                Button { guides.exportPDF(url) } label: { Label("PDF",systemImage: "doc.richtext").fixedSize() }.buttonStyle(.pill)
                Button { guides.handover(url) } label: { Label("An Claude Code",systemImage: "terminal").fixedSize() }.buttonStyle(.pill).help("Kopiert einen fertigen Auftrag für Claude Code in die Zwischenablage")
                Menu {
                    Button("Markdown kopieren") { guides.copyMarkdown(url) }
                    Button("Texte neu schreiben (\(guides.address.label))") { guides.rewriteTexts(url) }
                    Button("Bilder neu erzeugen und neu schwärzen") { if var g = guide { for i in g.steps.indices { g.steps[i].autoRedacted = nil }; guide = g; guides.save(g,at: url,regenerateImages: true) } }
                    Button("Aus der Aufnahme neu aufbauen") { guides.rebuild(url) }
                    Divider()
                    Toggle("„Automatisieren lassen“ auf der geteilten Seite",isOn: Binding(get: { guide?.showCallToAction ?? true },set: { value in update { $0.showCallToAction = value } }))
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Freigaben deaktivieren …",role: .destructive) { guides.revokeShare(url) }.disabled(GuideSharing.record(in: url) == nil)
                    Button("Löschen …",role: .destructive) { guides.delete(url) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 13,weight: .semibold)).frame(width: 30,height: 30) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .background(StudioTheme.fill,in: Circle()).accessibilityLabel("Weitere Aktionen")
            }.disabled(guides.phase != .idle).layoutPriority(1)
        }
        .padding(.horizontal,16).padding(.vertical,12).glassBar()
    }
    @ViewBuilder private func automation(_ guide: Guide) -> some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 6) { Image(systemName: "bolt").font(.system(size: 10,weight: .semibold)).foregroundStyle(StudioTheme.textTertiary); Text("Automatisierung").eyebrow() }
                Spacer()
                Button(brief == nil ? "Brief erstellen" : "Neu bewerten") { guides.writeBrief(url) }.buttonStyle(PillButtonStyle(height: 28,prominent: brief == nil)).disabled(guides.phase != .idle)
            }
            if let brief {
                Text(brief.summary).font(StudioFont.body).foregroundStyle(StudioTheme.text).textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 12,weight: .semibold)).foregroundStyle(StudioTheme.success)
                    Text("\(brief.groups.filter { $0.automatable != "nein" }.count) von \(brief.groups.count) Schrittgruppen bieten technische Ansatzpunkte.").font(StudioFont.bodyStrong).foregroundStyle(StudioTheme.text)
                }
                VStack(spacing: 6) {
                    ForEach(Array(brief.groups.enumerated()),id: \.offset) { _,group in
                        HStack(alignment: .top,spacing: 10) {
                            StatusBadge(text: group.automatable,tone: group.automatable == "ja" ? .success : group.automatable == "teilweise" ? .warning : .neutral).frame(width: 64,alignment: .leading)
                            VStack(alignment: .leading,spacing: 2) {
                                Text("\(group.title) · Schritt \(group.steps.map(String.init).joined(separator: ", "))").font(StudioFont.heading).foregroundStyle(StudioTheme.text)
                                Text("\(AutomationBrief.methodLabel(group.method)) · API \(group.apiStatus) · Aufwand \(group.effort): \(group.reason)").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false,vertical: true)
                            }
                        }.frame(maxWidth: .infinity,alignment: .leading).studioInset(padding: 10)
                    }
                }
                Text("Die Bewertung beschreibt die technische Machbarkeit. Nutze für deinen Nutzen und die Amortisation das Szenario oben. Die Übergabe berücksichtigt die gewählte Methode; sie aktiviert nichts.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
            } else {
                Text("Claude bewertet anhand deiner Schritte und Ergänzungen, was sich technisch automatisieren lässt und welche Fragen offen sind. Dauer, Häufigkeit und Kosten stellst du im gemeinsamen Szenario oben ein.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
            }
        }.studioCard(padding: 16)
    }
    private func stepCard(_ index: Int,_ step: GuideStep,count: Int) -> some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack(alignment: .top,spacing: 12) {
                Text("\(index+1)").font(.system(size: 12,weight: .bold,design: .rounded)).foregroundStyle(.white).frame(width: 26,height: 26).background(StudioTheme.accentGradient,in: Circle())
                VStack(alignment: .leading,spacing: 6) {
                    TextField("Schritt-Text",text: Binding(get: { guide?.steps[safe: index]?.text ?? "" },set: { value in guide?.steps[index].text = value; queueSave() }),axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 14,weight: .semibold)).foregroundStyle(StudioTheme.text).onSubmit { update { _ in } }.accessibilityLabel("Text von Schritt \(index+1)")
                    TextField("Tipp (optional)",text: Binding(get: { guide?.steps[safe: index]?.note ?? "" },set: { value in guide?.steps[index].note = value.isEmpty ? nil : value; queueSave() }),axis: .vertical)
                        .textFieldStyle(.plain).font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary).onSubmit { update { _ in } }.accessibilityLabel("Tipp zu Schritt \(index+1)")
                    Text(detail(step)).font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 2) {
                    iconButton("arrow.up","Nach oben") { update(images: true) { $0.steps.swapAt(index,index-1) } }.disabled(index == 0)
                    iconButton("arrow.down","Nach unten") { update(images: true) { $0.steps.swapAt(index,index+1) } }.disabled(index >= count-1)
                    iconButton("arrow.triangle.merge","Mit nächstem Schritt zusammenlegen") {
                        update(images: true) { g in let next = g.steps.remove(at: index+1); g.steps[index].text += " " + next.text; g.steps[index].redactions += next.redactions.filter { $0.reason == "manual" } }
                    }.disabled(index >= count-1)
                    iconButton("rectangle.slash","Bereich schwärzen") { update { _ in }; redacting = index }
                    iconButton("trash","Schritt löschen") { update(images: true) { $0.steps.remove(at: index) } }
                }.disabled(guides.phase != .idle)
            }
            if let image = step.image, let picture = NSImage(contentsOf: url.appendingPathComponent(image)) {
                Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 760).clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusSmall,style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: StudioTheme.radiusSmall,style: .continuous).strokeBorder(StudioTheme.hairline))
                    .id("\(image)-\(guides.revision)")
            }
            if !step.redactions.isEmpty {
                Label("Geschwärzt: " + Dictionary(grouping: step.redactions,by: \.reason).map { "\($0.value.count)× \(reasonLabel($0.key))" }.sorted().joined(separator: ", "),systemImage: "eye.slash")
                    .font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
            }
        }.studioCard(padding: 14)
    }
    private func detail(_ step: GuideStep) -> String {
        var parts = [step.action.rawValue]
        if let e = step.element { parts.append([e.roleDescription ?? e.role,e.label.map { "„\($0)“" }].compactMap { $0 }.joined(separator: " ")) }
        if let app = step.appName { parts.append(app) }
        if let url = step.url { parts.append(url) }
        parts.append(timestamp(step.time))
        return parts.joined(separator: " · ")
    }
    private func reasonLabel(_ reason: String) -> String {
        switch reason { case "email": "E-Mail"; case "iban": "IBAN"; case "phone": "Telefon"; case "card": "Karte"; case "password": "Passwort"; default: "manuell" }
    }
    private func iconButton(_ icon: String,_ help: String,action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.buttonStyle(IconButtonStyle(size: 26,filled: false)).help(help).accessibilityLabel(help)
    }
}

private struct RedactTarget: Identifiable { let index: Int; var id: Int { index } }

extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }

/// Drag rectangles over the step image to black them out; existing redactions can be removed.
struct RedactSheet: View {
    let url: URL
    @State var guide: Guide
    let index: Int
    let done: (Guide) -> Void
    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text("Bereich schwärzen · Schritt \(index+1)").font(StudioFont.pageTitle)
            Text("Ziehe ein Rechteck über alles, was nicht sichtbar sein soll. Gespeichert wird nur das geschwärzte Bild.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
            if let path = guide.steps[index].image, let picture = NSImage(contentsOf: url.appendingPathComponent(path)) {
                GeometryReader { geometry in
                    let size = fitted(picture.size,in: geometry.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: picture).resizable().frame(width: size.width,height: size.height)
                        ForEach(guide.steps[index].redactions) { r in
                            Rectangle().fill(Color.black.opacity(0.55)).overlay(Rectangle().strokeBorder(r.reason == "manual" ? StudioTheme.warning : StudioTheme.accent,lineWidth: 1.5))
                                .frame(width: r.rect.width*size.width,height: r.rect.height*size.height).offset(x: r.rect.x*size.width,y: r.rect.y*size.height)
                        }
                        if let start,let current {
                            let rect = CGRect(x: min(start.x,current.x),y: min(start.y,current.y),width: abs(current.x-start.x),height: abs(current.y-start.y))
                            Rectangle().fill(StudioTheme.warning.opacity(0.35)).frame(width: rect.width,height: rect.height).offset(x: rect.minX,y: rect.minY)
                        }
                    }
                    .frame(width: size.width,height: size.height)
                    .gesture(DragGesture(minimumDistance: 2).onChanged { value in start = value.startLocation; current = value.location }.onEnded { value in
                        let rect = GuideRect(x: min(value.startLocation.x,value.location.x)/size.width,y: min(value.startLocation.y,value.location.y)/size.height,
                                             width: abs(value.location.x-value.startLocation.x)/size.width,height: abs(value.location.y-value.startLocation.y)/size.height).clipped()
                        if rect.width > 0.004,rect.height > 0.004 { guide.steps[index].redactions.append(GuideRedaction(rect: rect,reason: "manual")) }
                        start = nil; current = nil
                    })
                }.frame(minWidth: 760,minHeight: 440)
            }
            HStack {
                Button("Letzte entfernen") { if !guide.steps[index].redactions.isEmpty { guide.steps[index].redactions.removeLast() } }.buttonStyle(.pill).disabled(guide.steps[index].redactions.isEmpty)
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button("Übernehmen") { done(guide) }.keyboardShortcut(.defaultAction).buttonStyle(AccentButtonStyle(height: 32))
            }
        }.padding(22).frame(width: 860,height: 620).background(StudioTheme.background)
    }
    private func fitted(_ image: CGSize,in box: CGSize) -> CGSize {
        let scale = min(box.width/max(1,image.width),box.height/max(1,image.height))
        return CGSize(width: image.width*scale,height: image.height*scale)
    }
}
