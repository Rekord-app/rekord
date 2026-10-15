import SwiftUI
import AppKit
import RecorderCore

/// One workspace, two ways to collect evidence. Existing files and commands remain valid.
struct ProcessesView: View {
    @EnvironmentObject var editor: EditorStore
    @ObservedObject var inventory: InventoryStore
    @ObservedObject var guides: GuideStore
    @State private var help = false
    @State private var query = ""
    @State private var onlyAutomatic = false
    @State private var sorting = "potential"
    private var selected: InventoryProcess? { inventory.catalog.processes.first { $0.id == inventory.selectedProcessID } }
    private var sorted: [InventoryProcess] {
        inventory.catalog.processes.filter {
            (!onlyAutomatic || $0.automatable != "nein") && (query.isEmpty || ($0.name+" "+$0.description+" "+$0.apps.joined(separator: " ")).localizedCaseInsensitiveContains(query))
        }.sorted { a,b in
            if sorting == "time" { return a.minutesPerWeek > b.minutesPerWeek }
            return (roi(a)?.monthlyNetValue ?? roi(a)?.capacityValuePerMonth ?? 0) > (roi(b)?.monthlyNetValue ?? roi(b)?.capacityValuePerMonth ?? 0)
        }
    }
    private func roi(_ p: InventoryProcess) -> ProcessROI? {
        ProcessROI(inputs: inventory.profile(p.id).roi,observedMinutes: p.timesPerWeek > 0 ? p.minutesPerWeek/p.timesPerWeek : nil,observedRuns: p.timesPerWeek > 0 ? p.timesPerWeek : nil,hourlyRate: guides.hourlyRate)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = inventory.error { notice(error,warning: true) }
            if !inventory.message.isEmpty { notice(inventory.message) }
            Group {
                switch inventory.hubTab {
                case 1: library
                case 2: GuidesView(guides: guides)
                case 3: InventoryView(inventory: inventory)
                default: overview
                }
            }.frame(maxWidth: .infinity,maxHeight: .infinity)
        }.background(StudioTheme.background)
        .sheet(isPresented: $help) { ProcessHelpView() }
        .sheet(isPresented: $inventory.showSettings) { InventorySettings(inventory: inventory,guides: guides).frame(width: 600,height: 650) }
        .onAppear { inventory.reload(); guides.reload() }
    }
    private var header: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading,spacing: 4) {
                    Text("Prozesse").font(.system(size: 26,weight: .semibold)).foregroundStyle(StudioTheme.text)
                    Text("Arbeit verstehen. Abläufe erklären. Zeit zurückgewinnen.").font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                Button { help = true } label: { Label("So holst du mehr heraus",systemImage: "questionmark.circle") }.buttonStyle(.pill)
                Button { inventory.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(IconButtonStyle()).help("Erfassung, Stundensatz und Datenschutz")
            }
            HStack {
                HStack(spacing: 4) {
                    tab("Übersicht",0); tab("Prozess-Liste",1); tab("Anleitungen",2); tab("Tagesverlauf",3)
                }
                Spacer(minLength: 12)
                if inventory.phase != .off {
                    Circle().fill(inventory.phase == .paused || inventory.currentPause != nil ? StudioTheme.warning : StudioTheme.success).frame(width: 6,height: 6)
                    Text(inventory.phase == .paused || inventory.currentPause != nil ? "Erfassung pausiert" : "Entdeckt lokal").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                    Menu {
                        Button("15 Minuten pausieren") { inventory.pause() }
                        Button("Fortsetzen") { inventory.resume() }
                        Button("Entdecken stoppen") { inventory.stop() }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                }
                if inventory.processing { ProgressView().controlSize(.small) }
                Button("Auswerten") { Task { await inventory.buildCatalog() } }.buttonStyle(.pill).disabled(inventory.processing)
            }
        }.padding(24).background(StudioTheme.sidebar)
    }
    private func tab(_ title: String,_ index: Int) -> some View {
        Button { inventory.hubTab = index } label: {
            Text(title).font(StudioFont.bodyStrong).padding(.horizontal,13).padding(.vertical,8)
                .foregroundStyle(inventory.hubTab == index ? StudioTheme.text : StudioTheme.textSecondary)
                .background(inventory.hubTab == index ? StudioTheme.fillActive : .clear,in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private func notice(_ text: String,warning: Bool = false) -> some View {
        HStack { Image(systemName: warning ? "exclamationmark.circle" : "checkmark.circle"); Text(text).textSelection(.enabled); Spacer(); Button { inventory.error = nil; inventory.message = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            .font(StudioFont.caption).foregroundStyle(warning ? StudioTheme.warning : StudioTheme.textSecondary).padding(12)
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 24) {
                HStack(spacing: 14) {
                    stat("Erkannte Prozesse",value: "\(inventory.catalog.processes.count)",detail: "Beobachtete Tage: \(inventory.catalog.days.count)",symbol: "square.stack.3d.up")
                    stat("Dokumentierte Abläufe",value: "\(guides.guides.count)",detail: "Mit Schritten, Bildern und Erklärung",symbol: "list.number")
                    stat("Arbeitszeit im Katalog",value: "\(processNumber(inventory.catalog.processes.reduce(0) { $0+$1.minutesPerWeek }/60)) h/Woche",detail: "Hochrechnung, noch keine Ersparnis",symbol: "clock")
                }
                VStack(alignment: .leading,spacing: 8) {
                    Text("Wo möchtest du anfangen?").font(.system(size: 21,weight: .semibold))
                    Text("Lass wiederkehrende Arbeit entdecken oder zeige direkt einen Ablauf, den du verbessern möchtest.").foregroundStyle(StudioTheme.textSecondary)
                }
                HStack(alignment: .top,spacing: 16) {
                    entryCard(icon: "sparkle.magnifyingglass",title: "Meinen Arbeitstag verstehen",subtitle: "ENTDECKEN",text: "Rekord sammelt lokale Arbeitsblöcke und fragt gelegentlich nach dem Warum. Daraus entsteht deine Prozess-Liste.",tip: "Für gute Ergebnisse: einen typischen Tag nutzen und kurze Rückfragen beantworten.",button: inventory.phase == .off ? "Entdecken starten" : "Tagesverlauf öffnen") {
                        if inventory.phase == .off { inventory.start() } else { inventory.hubTab = 3 }
                    }
                    entryCard(icon: "cursorarrow.click.2",title: "Einen Ablauf zeigen",subtitle: "ERKLÄREN",text: "Führe eine Aufgabe einmal vor und erkläre laut Ziel, Entscheidungen und Sonderfälle. Rekord erstellt die Anleitung.",tip: "Für gute Ergebnisse: ein Ablauf pro Aufnahme, mit einem konkreten Beispiel.",button: guides.recording ? "Zur laufenden Anleitung" : "Ablauf aufnehmen") {
                        editor.showGuides(); if guides.phase == .idle { guides.start() }
                    }
                }
                if !GuideAccessibility.trusted && !SnapshotDiagnostics.active {
                    HStack(alignment: .top,spacing: 12) {
                        Image(systemName: "hand.raised").foregroundStyle(StudioTheme.warning)
                        VStack(alignment: .leading,spacing: 5) {
                            Text("Für gute Ergebnisse fehlen noch die Bedienungshilfen.").font(StudioFont.bodyStrong)
                            Text("Damit erkennt Rekord Fenster und Knöpfe. Ohne das Recht entdeckt es nur App-Namen; Anleitungen bleiben unvollständig.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                        }
                        Spacer(); Button("Freigeben") { GuideSettingsLink.openAccessibility() }.buttonStyle(.pill)
                    }.studioCard()
                }
                if !sorted.filter({ $0.automatable != "nein" }).isEmpty {
                    HStack { Text("Hier lohnt sich der nächste Blick").font(.system(size: 19,weight: .semibold)); Spacer(); Button("Alle Prozesse") { inventory.hubTab = 1 }.buttonStyle(.pill) }
                    Text("Sortiert nach deinem Szenario (Standard: 50 % automatisierter Zeitanteil). Prüfe zuerst die Annahmen; ein hoher Arbeitswert allein macht noch keinen guten Automatisierungsfall.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                    ForEach(Array(sorted.filter { $0.automatable != "nein" }.prefix(3))) { p in
                        Button { inventory.selectedProcessID = p.id; inventory.hubTab = 1 } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "arrow.up.right").foregroundStyle(StudioTheme.accent)
                                VStack(alignment: .leading,spacing: 4) { Text(p.name).font(StudioFont.bodyStrong); Text("\(p.occurrences.count) Beobachtungen · \(AutomationBrief.methodLabel(p.method))").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary) }
                                Spacer()
                                VStack(alignment: .trailing,spacing: 4) { Text("\(processNumber(roi(p)?.monthlyNetValue ?? roi(p)?.capacityValuePerMonth ?? 0,0)) €/Monat").font(.system(size: 17,weight: .semibold,design: .rounded)); Text(roi(p)?.monthlyNetValue == nil ? "Szenario · vor Kosten" : "Szenario · nach Kosten").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary) }
                            }.studioCard()
                        }.buttonStyle(.plain)
                    }
                } else {
                    Label("Dein erster Ablauf ist der beste Start. Du brauchst noch keinen vollständigen Arbeitstag.",systemImage: "lightbulb").font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary).studioInset()
                }
                Text("Inventur ist experimentell. Bilder und Aufnahmen bleiben lokal; für KI-Texte wird maskierter Text an Anthropic gesendet. Ausschlüsse vor dem Start prüfen.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
            }.padding(24)
        }
    }
    private func stat(_ title: String,value: String,detail: String,symbol: String) -> some View {
        VStack(alignment: .leading,spacing: 10) {
            Label(title,systemImage: symbol).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
            Text(value).font(.system(size: 25,weight: .semibold,design: .rounded)).monospacedDigit()
            Text(detail).font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
        }.frame(maxWidth: .infinity,alignment: .leading).studioCard()
    }
    private func entryCard(icon: String,title: String,subtitle: String,text: String,tip: String,button: String,action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading,spacing: 14) {
            HStack { Image(systemName: icon).font(.system(size: 23)).foregroundStyle(StudioTheme.accent); Spacer(); Text(subtitle).eyebrow() }
            Text(title).font(.system(size: 18,weight: .semibold))
            Text(text).font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false,vertical: true)
            Text(tip).font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary).fixedSize(horizontal: false,vertical: true)
            Button(button,action: action).buttonStyle(AccentButtonStyle(height: 34)).disabled(editor.busy || guides.phase == .starting || guides.phase == .processing || editor.meetings.recording)
        }.frame(maxWidth: .infinity,alignment: .leading).studioCard(padding: 22)
    }
    private var library: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading,spacing: 12) {
                SearchField(placeholder: "Prozess oder App suchen",text: $query)
                Toggle("Automatisierbare",isOn: $onlyAutomatic).font(StudioFont.caption)
                Picker("Sortierung",selection: $sorting) { Text("Potenzial").tag("potential"); Text("Zeitaufwand").tag("time") }.font(StudioFont.caption)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(sorted) { p in
                            Button { inventory.selectedProcessID = p.id } label: {
                                VStack(alignment: .leading,spacing: 7) {
                                    Text(p.name).font(StudioFont.bodyStrong).multilineTextAlignment(.leading)
                                    HStack { Text("\(processNumber(p.minutesPerWeek/60)) h/Woche"); Spacer(); Text(inventory.profile(p.id).reviewed ? "Geprüft" : "Entdeckt") }.font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                                }.padding(12).frame(maxWidth: .infinity,alignment: .leading).background(inventory.selectedProcessID == p.id ? StudioTheme.fillActive : .clear,in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                        if sorted.isEmpty { Text("Noch keine passenden Prozesse. Entdecke deinen Tag und wähle anschließend „Auswerten“.").font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary).padding(.top,20) }
                    }
                }
                if inventory.teamMode { Button("Freigegebene Prozesse exportieren") { inventory.exportTeam() }.buttonStyle(.pill).disabled(inventory.approved.isEmpty) }
            }.padding(16).frame(width: 270)
            Rectangle().fill(StudioTheme.hairline).frame(width: 1)
            if let selected { ProcessDetailView(process: selected,inventory: inventory,guides: guides).id(selected.id) }
            else { EmptyState(icon: "square.stack.3d.up",title: "Wähle einen Prozess",text: "Prüfe die Beobachtungen, verknüpfe eine Anleitung und rechne deinen möglichen Nutzen durch.") }
        }
    }
}

func processNumber(_ value: Double,_ digits: Int = 1) -> String {
    let f = NumberFormatter(); f.locale = Locale(identifier: "de_DE"); f.maximumFractionDigits = digits
    return f.string(from: NSNumber(value: value)) ?? "–"
}

struct ProcessHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading,spacing: 22) {
            HStack { Text("Vom Alltag zur besseren Arbeitsweise").font(.title2.bold()); Spacer(); Button("Fertig") { dismiss() }.buttonStyle(.pill) }
            tip("1", "Entdecken: einen typischen Tag beobachten", "Prüfe Ausschlüsse, starte die Inventur und arbeite normal. Beantworte Rückfragen mit Tätigkeit, Ziel und Grund. Zwei bis drei typische Tage liefern eine bessere Grundlage als ein ungewöhnlicher Nachmittag.")
            tip("2", "Erklären: einen konkreten Ablauf vormachen", "Starte beim Auslöser und ende beim fertigen Ergebnis. Erkläre, woher die Daten kommen, warum du etwas entscheidest und was bei fehlenden Daten passiert. Verknüpfe die Anleitung mit dem erkannten Prozess.")
            tip("3", "Rechnen: Restarbeit und Kosten mitdenken", "Die gesamte Arbeitszeit ist noch keine Ersparnis. Stelle den erwarteten Automatisierungsanteil ein, ziehe menschliche Prüfung ab und ergänze Einrichtungs- und Betriebskosten. Aufnahmedauer kann Erklärzeit enthalten – korrigiere sie.")
            tip("4", "Umsetzen: klein anfangen und prüfen", "Wähle einen häufigen, klaren Ablauf. Ergänze einen Sonderfall und ein messbares Erfolgskriterium. Übergib das Paket an Claude Code; prüfe zehn Testfälle und drei Ergebnisse selbst, bevor du etwas aktivierst.")
            Text("Freie Kapazität wird erst dann zu einem wirtschaftlichen Vorteil, wenn du sie sinnvoll nutzen kannst. Die Rechnung ist eine Planungshilfe, keine Garantie für mehr Umsatz oder weniger Ausgaben.").font(.callout).foregroundStyle(StudioTheme.textSecondary)
        }.padding(28).frame(width: 680).background(StudioTheme.background)
    }
    private func tip(_ n: String,_ title: String,_ text: String) -> some View {
        HStack(alignment: .top,spacing: 14) {
            Text(n).font(.headline).frame(width: 28,height: 28).background(StudioTheme.fillActive,in: Circle())
            VStack(alignment: .leading,spacing: 6) { Text(title).font(.headline); Text(text).font(.callout).foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false,vertical: true) }
        }
    }
}
