import SwiftUI
import AppKit
import RecorderCore

struct InventoryView: View {
    @EnvironmentObject var editor: EditorStore
    @ObservedObject var inventory: InventoryStore
    @State private var tab = 0
    @State private var selectedBlock: InventoryBlock?
    init(inventory: InventoryStore, initialTab: Int = 0) { self.inventory = inventory; _tab = State(initialValue: initialTab) }
    var body: some View {
        VStack(alignment: .leading,spacing: 18) {
            HStack {
                VStack(alignment: .leading) { Text("Arbeits-Inventur · Experimentell").font(StudioFont.title); Text("Deinen Alltag verstehen. Prozesse entdecken.").foregroundStyle(.secondary) }
                Spacer()
                Button("Einstellungen") { inventory.showSettings = true }
            }
            VStack(alignment: .leading,spacing: 12) {
                HStack {
                    Label(inventory.phase == .off ? "Bereit" : inventory.phase == .paused ? "Pausiert" : inventory.currentPause.map { "Pause: \($0)" } ?? "Erfasst lokal",systemImage: "circle.fill")
                        .foregroundStyle(inventory.phase == .running && inventory.currentPause == nil ? .green : .secondary)
                    Spacer()
                    Text("Heute \(Int(inventory.capturedSeconds/60)) Min. · \(inventory.usage.total) Tokens").monospacedDigit()
                    if inventory.phase == .off { Button("Inventur starten") { inventory.start() }.buttonStyle(.borderedProminent) }
                    else if inventory.phase == .paused { Button("Fortsetzen") { inventory.resume() } }
                    else { Button("15 Min. pausieren") { inventory.pause() }; Button("Stoppen") { inventory.stop() } }
                }
                Text("Bilder bleiben auf dem Mac. An Claude geht nur maskierter Text. Erkannte private Fenster, Banking und Passwort-Manager werden ausgeschlossen.").font(.callout).foregroundStyle(.secondary)
                HStack { Button("Ausschlüsse bearbeiten") { inventory.showSettings = true }; Link("Datenschutz",destination: URL(string: "https://github.com/Rekord-app/rekord/blob/main/docs/PRIVACY.md")!) }.font(.caption)
                if !GuideAccessibility.trusted { Text("Bedienungshilfen fehlen: derzeit nur App-Namen, keine Browser-Bilder oder Fenstertitel. In Datenschutz & Sicherheit → Bedienungshilfen freigeben.").font(.caption).foregroundStyle(.orange) }
            }.padding(16).studioInset()
            if let error = inventory.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if !inventory.message.isEmpty { Text(inventory.message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Picker("Ansicht",selection: $tab) { Text("Tag").tag(0); Text("Prozesse").tag(1) }.pickerStyle(.segmented).frame(width: 250)
                Spacer()
                if inventory.processing { ProgressView().controlSize(.small) }
                Button("Jetzt auswerten") { Task { await inventory.buildCatalog() } }.disabled(inventory.processing)
            }
            if tab == 0 { timeline } else { processes }
        }.padding(24).frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)
        .sheet(isPresented: $inventory.showSettings) { InventorySettings(inventory: inventory,guides: editor.guides).frame(width: 600,height: 650) }
        .sheet(item: $selectedBlock) { block in InventoryBlockDetail(inventory: inventory,block: block).frame(width: 750,height: 550) }
        .onAppear { inventory.reload() }
    }
    private var timeline: some View {
        VStack(alignment: .leading) {
            Picker("Tag",selection: $inventory.selectedDay) { ForEach(Array(Set(InventoryFolder.days(in: inventory.root)+[InventoryFolder.day()])).sorted().reversed(),id: \.self) { Text($0).tag($0) } }.frame(width: 230).onChange(of: inventory.selectedDay) { inventory.reload() }
            if inventory.blocks.isEmpty { Text("Hier erscheinen Arbeitsblöcke nach der ersten Auswertung. Kurze Unterbrechungen zählen nicht als Prozess.").foregroundStyle(.secondary).padding(.top,30) }
            List(inventory.blocks) { block in
                HStack {
                    Image(systemName: "app.dashed").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading) { Text(block.title.isEmpty ? block.apps.joined(separator: ", ") : block.title); Text("\(block.start.formatted(date: .omitted,time: .shortened))–\(block.end.formatted(date: .omitted,time: .shortened)) · \(Int(block.activeSeconds/60)) Min.").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("Ansehen") { selectedBlock = block }; Button("Löschen",role: .destructive) { Task { await inventory.delete(block) } }.disabled(inventory.processing)
                }.padding(.vertical,6)
            }.scrollContentBackground(.hidden)
        }
    }
    private var processes: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 14) {
                Text("Arbeitswert bei \(Int(inventory.hourlyRate())) €/Std. Hochrechnung aus \(inventory.catalog.days.count) Arbeitstagen; keine garantierte Ersparnis.").font(.caption).foregroundStyle(.secondary)
                if inventory.catalog.processes.isEmpty { Text("Noch keine Prozesse. Starte die Inventur und werte deinen Tag aus.").padding(.vertical,30) }
                ForEach(inventory.catalog.processes) { p in
                    DisclosureGroup {
                        VStack(alignment: .leading,spacing: 10) {
                            Text(p.description).textSelection(.enabled)
                            Text("Auslöser: \(p.trigger)")
                            ForEach(Array(p.steps.enumerated()),id: \.offset) { step in Text("\(step.offset+1). \(step.element)") }
                            Text("\(AutomationBrief.methodLabel(p.method)) · API \(p.apiStatus) · Aufwand \(p.effort)").font(.callout)
                            Text("Offen: \(p.openQuestions.joined(separator: "; "))").font(.callout)
                            Text("Erfolg: \(p.successCriteria.joined(separator: "; "))").font(.callout)
                            HStack {
                                Button("An Claude Code übergeben") { Task { await inventory.handover(p) } }.disabled(inventory.processing)
                                Button("Als Anleitung aufnehmen") { editor.guides.nextTitle = p.name; editor.showGuides(); editor.guides.start() }.disabled(editor.busy || editor.meetings.recording || editor.guides.phase != .idle)
                                Button("Kein Prozess") { inventory.reject(p) }.disabled(inventory.processing)
                            }
                            if inventory.teamMode {
                                TextField("Name für Export",text: Binding(get: { inventory.exportNames[p.id] ?? p.name },set: { inventory.exportNames[p.id] = $0; inventory.approved.remove(p.id) }))
                                TextField("Schritte für Export (eine Zeile pro Schritt)",text: Binding(get: { inventory.exportSteps[p.id] ?? p.steps.joined(separator: "\n") },set: { inventory.exportSteps[p.id] = $0; inventory.approved.remove(p.id) }),axis: .vertical)
                                TextField("Beschreibung für Export",text: Binding(get: { inventory.exportEdits[p.id] ?? p.description },set: { inventory.exportEdits[p.id] = $0; inventory.approved.remove(p.id) }),axis: .vertical)
                                Toggle("Diesen Prozess geprüft und zum Export freigegeben",isOn: Binding(get: { inventory.approved.contains(p.id) },set: { if $0 { inventory.approved.insert(p.id) } else { inventory.approved.remove(p.id) } }))
                            }
                        }.padding(.top,10)
                    } label: {
                        HStack { Text(p.name).font(.headline); Spacer(); Text("\(String(format: "%.1f",p.minutesPerWeek/60)) Std./Woche · \(String(format: "%.1f",p.timesPerWeek))×").foregroundStyle(.secondary); Text("\(Int(p.euroPerMonth)) €/Monat").monospacedDigit(); Text(p.automatable).font(.caption).padding(6).background(.quaternary,in: Capsule()) }
                    }.padding(16).studioInset()
                }
                if inventory.teamMode { Button("Prozess-Liste für mein Unternehmen exportieren") { inventory.exportTeam() }.disabled(inventory.approved.isEmpty) }
            }
        }
    }
}
private struct InventorySettings: View {
    @ObservedObject var inventory: InventoryStore
    @ObservedObject var guides: GuideStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            Form {
                Section("Erfassung") {
                    Text("Zusätzliche ausgeschlossene Bundle-IDs, eine pro Zeile. Standard: Passwort-Manager, Nachrichten, WhatsApp, Signal, Banking, Rekord.").font(.caption)
                    TextEditor(text: $inventory.exclusions).frame(height: 90)
                    Stepper("Rückfragen pro Tag: \(inventory.questionsPerDay)",value: $inventory.questionsPerDay,in: 0...15)
                    TextField("Tagesbudget (Tokens)",value: $inventory.tokenBudget,format: .number)
                    TextField("Stundensatz (€)",value: $guides.hourlyRate,format: .number)
                    Stepper("Katalog um \(inventory.catalogHour):\(String(format: "%02d",inventory.catalogMinute))",value: $inventory.catalogHour,in: 0...23)
                    Stepper("Minute: \(inventory.catalogMinute)",value: $inventory.catalogMinute,in: 0...59)
                }
                Section("Aufbewahrung") {
                    Stepper("Bilder: \(inventory.imageDays) Tage",value: $inventory.imageDays,in: 0...30)
                    Stepper("Rohproben: \(inventory.sampleDays) Tage",value: $inventory.sampleDays,in: 1...90)
                    Button("Inventur-Bilder jetzt löschen",role: .destructive) { inventory.deleteImages() }
                }
                Section("Team") {
                    Toggle("Für ein Team nutzen",isOn: $inventory.teamMode)
                    Text("Du prüfst jeden Prozess vor dem lokalen Export. Keine Zeitachse, Rohproben, Bilder oder wörtlichen Antworten im Export. Die Menüleiste zeigt jede laufende Inventur.").font(.caption)
                }
                Text("Für Erfassung nach der Anmeldung: Rekord → Einstellungen → Beim Anmelden starten. Die Inventur merkt sich Start und Pause.").font(.caption)
            }.formStyle(.grouped)
            Button("Fertig") { dismiss() }.padding()
        }
    }
}
private struct InventoryBlockDetail: View {
    @ObservedObject var inventory: InventoryStore
    let block: InventoryBlock
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 12) {
                HStack { Text(block.title).font(.title2); Spacer(); Button("Schließen") { dismiss() } }
                Text(block.activity); Text(block.goal)
                ForEach(inventory.checkIns(day: inventory.selectedDay).filter { $0.blockID == block.id }) { c in Text("\(c.question)\n\(c.answer)") }
                let dir = inventory.root.appendingPathComponent(inventory.selectedDay)
                let samples = ((try? InventoryFile.samples(in: dir)) ?? []).filter { $0.start >= block.start && $0.start < block.end }
                ForEach(samples.compactMap(\.snapshot),id: \.self) { path in
                    if let image = NSImage(contentsOf: dir.appendingPathComponent(path)) { Image(nsImage: image).resizable().scaledToFit() }
                }
            }.padding(24)
        }
    }
}
