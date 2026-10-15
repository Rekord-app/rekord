import SwiftUI
import AppKit
import RecorderCore

struct InventoryView: View {
    @ObservedObject var inventory: InventoryStore
    @State private var selectedBlock: InventoryBlock?
    var body: some View {
        timeline.padding(20)
            .sheet(item: $selectedBlock) { block in InventoryBlockDetail(inventory: inventory,block: block).frame(width: 750,height: 550) }
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
}
struct InventorySettings: View {
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
