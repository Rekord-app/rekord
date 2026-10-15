import SwiftUI
import AppKit
import RecorderCore

extension EditorStore {
    static var storagePolicy: Storage.Policy {
        get { (UserDefaults.standard.data(forKey: "storagePolicy").flatMap { try? JSONDecoder().decode(Storage.Policy.self,from: $0) }) ?? Storage.Policy() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue),forKey: "storagePolicy") }
    }
    /// Folders the cleanup must leave alone right now.
    var storageProtected: Set<String> { Set([directory,recordingDirectory].compactMap { $0?.standardizedFileURL.path }) }
    /// Runs the automatic cleanup once a day, never during a recording or export.
    func cleanUpStorageIfDue() {
        guard phase == .idle, !CommandLine.arguments.contains("--exit-after-diagnostics") else { return }
        let last = UserDefaults.standard.object(forKey: "storageCleanupLast") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86400 else { return }
        UserDefaults.standard.set(Date(),forKey: "storageCleanupLast")
        cleanUpStorage(manual: false)
    }
    /// Applies the storage policy; archived takes keep their place in the recent list under the new path.
    func cleanUpStorage(manual: Bool) {
        let folder = captureRoot ?? RecordingsFolder.url
        let actions = Storage.plan(Storage.scan(folder),policy: Self.storagePolicy,protected: storageProtected)
        guard !actions.isEmpty else { if manual { status = "Nichts aufzuräumen" }; return }
        let freed = actions.reduce(Int64(0)) { $0+$1.item.bytes }
        let result = Storage.apply(actions)
        for move in result.moved {
            if let target = move.to { recent = recent.map { $0.standardizedFileURL == move.from.standardizedFileURL ? target : $0 } }
            else { recent.removeAll { $0.standardizedFileURL == move.from.standardizedFileURL } }
        }
        UserDefaults.standard.set(recent.map(\.path),forKey: "recentProjects")
        let trashed = result.moved.filter { $0.to == nil }.count, archived = result.moved.count-trashed
        var parts: [String] = []
        if trashed > 0 { parts.append("\(trashed) Loom-Video\(trashed == 1 ? "" : "s") in den Papierkorb") }
        if archived > 0 { parts.append("\(archived) Studio-Aufnahme\(archived == 1 ? "" : "n") ausgelagert") }
        status = "Aufgeräumt: \(parts.joined(separator: ", ")) · \(Storage.format(freed)) frei"
        if !result.failed.isEmpty { self.error = "Einige Aufnahmen konnten nicht verschoben werden:\n"+result.failed.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n") }
    }
}

/// Settings → Speicher: what takes how much space, and the automatic cleanup.
struct StorageSettingsSection: View {
    @EnvironmentObject var store: EditorStore
    @State private var usage: Storage.Usage?
    @State private var policy = EditorStore.storagePolicy
    @State private var preview: (count: Int,bytes: Int64) = (0,0)
    var body: some View {
        Section {
            if let usage {
                LabeledContent("Aufnahmen") { Text("\(Storage.format(usage.recordings))  (Studio \(Storage.format(usage.studio)) · Loom \(Storage.format(usage.loom)))").monospacedDigit() }
                LabeledContent("Meetings · Anleitungen") { Text("\(Storage.format(usage.meetings)) · \(Storage.format(usage.guides))").monospacedDigit() }
                LabeledContent("Inventur: Bilder · Proben") { Text("\(Storage.format(usage.inventoryImages)) · \(Storage.format(usage.inventorySamples))") }
                Button("Inventur-Bilder jetzt löschen",role: .destructive) { store.inventory.deleteImages(); refresh() }
                LabeledContent("Frei auf dem Mac") { Text(Storage.format(usage.freeOnDisk)).monospacedDigit().foregroundStyle(usage.freeOnDisk < 20_000_000_000 ? StudioTheme.warning : StudioTheme.text) }
            } else { ProgressView().controlSize(.small) }
            Toggle(isOn: Binding(get: { policy.loomTrashDays != nil },set: { policy.loomTrashDays = $0 ? 30 : nil })) {
                Text("Geteilte Loom-Videos in den Papierkorb")
                Text("Der Link bleibt bestehen; aus dem Papierkorb lässt sich alles zurückholen.").font(StudioFont.caption)
            }
            if policy.loomTrashDays != nil {
                Picker("… wenn unbenutzt seit",selection: Binding(get: { policy.loomTrashDays ?? 30 },set: { policy.loomTrashDays = $0 })) {
                    ForEach([14,30,60,90],id: \.self) { Text("\($0) Tagen").tag($0) }
                }
            }
            Toggle(isOn: Binding(get: { policy.studioArchiveDays != nil },set: { on in
                policy.studioArchiveDays = on ? 60 : nil
                if on && policy.archiveFolder == nil { chooseArchive() }
            })) {
                Text("Studio-Aufnahmen auslagern")
                Text("Zum Beispiel auf eine externe Platte. Dort bleiben sie öffenbar.").font(StudioFont.caption)
            }
            if policy.studioArchiveDays != nil {
                Picker("… wenn unbenutzt seit",selection: Binding(get: { policy.studioArchiveDays ?? 60 },set: { policy.studioArchiveDays = $0 })) {
                    ForEach([30,60,90,180],id: \.self) { Text("\($0) Tagen").tag($0) }
                }
                LabeledContent("Ziel") {
                    HStack {
                        Text(policy.archiveFolder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "kein Ordner gewählt").lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(policy.archiveFolder.map { FileManager.default.fileExists(atPath: $0) } == true ? StudioTheme.text : StudioTheme.warning)
                        Button("Wählen …") { chooseArchive() }
                    }
                }
            }
            HStack {
                Text(preview.count == 0 ? "Gerade nichts aufzuräumen." : "Jetzt möglich: \(preview.count) Aufnahme\(preview.count == 1 ? "" : "n") · \(Storage.format(preview.bytes))")
                    .font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Button("Jetzt aufräumen") { store.cleanUpStorage(manual: true); refresh() }.disabled(preview.count == 0 || store.phase != .idle)
            }
        } header: { Text("Speicher") } footer: {
            Text("Läuft automatisch einmal am Tag. Meetings, Anleitungen und die gerade geöffnete Aufnahme bleiben immer unangetastet.")
        }
        .onAppear(perform: refresh)
        .onChange(of: policy) { EditorStore.storagePolicy = policy; refresh() }
    }
    private func refresh() {
        let folder = store.captureRoot ?? RecordingsFolder.url, policy = policy, protected = store.storageProtected
        Task.detached {
            let items = Storage.scan(folder), usage = Storage.usage(folder)
            let plan = Storage.plan(items,policy: policy,protected: protected)
            await MainActor.run { self.usage = usage; self.preview = (plan.count,plan.reduce(0) { $0+$1.item.bytes }) }
        }
    }
    private func chooseArchive() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Ordner für ausgelagerte Studio-Aufnahmen (z. B. auf einer externen Platte)"
        if panel.runModal() == .OK, let url = panel.url { policy.archiveFolder = url.path }
        else if policy.archiveFolder == nil { policy.studioArchiveDays = nil }
    }
}

/// Settings → Teilen: how long new video links live on the server.
struct ShareExpiryPicker: View {
    @AppStorage("shareExpiryDays") private var days = 90
    var body: some View {
        Picker("Neue Video-Links laufen ab nach",selection: $days) {
            Text("30 Tagen").tag(30); Text("90 Tagen").tag(90); Text("1 Jahr").tag(365); Text("Nie").tag(0)
        }
    }
}
