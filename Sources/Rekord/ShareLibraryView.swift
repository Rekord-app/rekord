import SwiftUI
import RecorderCore

struct ShareLibraryView: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) var dismiss
    @State private var videos: [SharedVideo] = []
    @State private var message = "Freigaben werden geladen …"
    @State private var deleting: String?
    @State private var revokeCandidate: SharedVideo?
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            HStack {
                VStack(alignment: .leading,spacing: 2) {
                    Text("Geteilte Aufnahmen").font(StudioFont.pageTitle)
                    Text("Deaktivierte Links sind sofort nicht mehr aufrufbar; lokale Projekte bleiben erhalten.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                Button("Fertig") { dismiss() }.buttonStyle(PillButtonStyle(prominent: true)).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(videos,id: \.id) { video in
                        HStack(alignment: .center,spacing: 12) {
                            Image(systemName: "play.rectangle").font(.system(size: 14)).foregroundStyle(StudioTheme.textTertiary).frame(width: 22)
                            VStack(alignment: .leading,spacing: 2) {
                                Text(video.title).font(StudioFont.heading).lineLimit(1)
                                Text("\(video.bytes/1024/1024) MB · \(String(video.createdAt.prefix(10))) · \(expiryText(video))").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                            }
                            Spacer()
                            if video.expiresAt != nil {
                                Button("Behalten") { keep(video) }.buttonStyle(.pill).disabled(deleting != nil)
                                    .help("Link läuft nicht mehr ab und bleibt dauerhaft auf dem Server")
                            }
                            Button("Link kopieren") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(video.url.absoluteString,forType: .string); message = "Link kopiert" }.buttonStyle(.pill)
                            Button("Öffnen") { NSWorkspace.shared.open(video.url) }.buttonStyle(.pill)
                            Button("Deaktivieren",role: .destructive) { revokeCandidate = video }.buttonStyle(.pill).disabled(deleting != nil)
                        }.padding(.horizontal,12).padding(.vertical,10).studioInset(padding: 0)
                    }
                    if videos.isEmpty { Text(message).font(StudioFont.body).foregroundStyle(StudioTheme.textTertiary).frame(maxWidth: .infinity).padding(.top,40) }
                }
            }.frame(minHeight: 250)
            if !videos.isEmpty { Text(message).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary) }
        }.padding(24).frame(width: 640,height: 500).background(StudioTheme.background)
        .task {
            do { videos = try await store.shareClient().videos(); message = videos.isEmpty ? "Noch keine aktiven Freigaben." : "\(videos.count) aktive Freigaben" }
            catch { message = error.localizedDescription }
        }
        .confirmationDialog("Diesen Freigabelink deaktivieren?",isPresented: Binding(get: { revokeCandidate != nil },set: { if !$0 { revokeCandidate = nil } })) {
            Button("Link deaktivieren",role: .destructive) {
                guard let video = revokeCandidate else { return }; revokeCandidate = nil; deleting = video.id
                Task {
                    defer { deleting = nil }
                    do {
                        try await store.shareClient().revoke(video.id); videos.removeAll { $0.id == video.id }
                        if store.shareReceipt?.video.id == video.id {
                            if let directory = store.directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent("share.json")) }
                            store.shareReceipt = nil
                        }
                        message = "Link deaktiviert"
                    } catch { message = error.localizedDescription }
                }
            }
        }
    }
    private func expiryText(_ video: SharedVideo) -> String {
        guard let date = video.expiryDate else { return "dauerhaft" }
        return "läuft ab am \(date.formatted(date: .numeric,time: .omitted))"
    }
    private func keep(_ video: SharedVideo) {
        deleting = video.id
        Task {
            defer { deleting = nil }
            do {
                let updated = try await store.shareClient().setExpiry(video.id,expiresAt: nil)
                if let i = videos.firstIndex(where: { $0.id == video.id }) { videos[i] = updated }
                message = "Link bleibt dauerhaft"
            } catch { message = error.localizedDescription }
        }
    }
}
