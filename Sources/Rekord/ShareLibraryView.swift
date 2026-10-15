import SwiftUI
import RecorderCore

struct ShareLibraryView: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) var dismiss
    @State private var videos: [SharedVideo] = []
    @State private var guides: [SharedGuide] = []
    @State private var message = "Freigaben werden geladen …"
    @State private var busy = false
    @State private var lifecycle = false
    @State private var supportsOffers = false
    @State private var offerVideo: SharedVideo?
    @State private var offers = false
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            HStack {
                VStack(alignment: .leading,spacing: 2) {
                    Text("Geteilte Aufnahmen und Anleitungen").font(StudioFont.pageTitle)
                    Text("Widerruf sperrt auch verknüpfte alte Videos und Anleitungsversionen.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                if supportsOffers { Button("Video-Angebote") { offers = true }.buttonStyle(.pill) }
                Button("Fertig") { dismiss() }.buttonStyle(PillButtonStyle(prominent: true)).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(guides,id: \.id) { guide in
                        shareRow(title: guide.title,detail: "Anleitung · \(guide.createdAt.prefix(10))",url: guide.url) {
                            revoke(guideID: guide.id)
                        }
                    }
                    ForEach(videos,id: \.id) { video in
                        shareRow(title: video.title,detail: "Video · \(video.bytes/1024/1024) MB · \(expiryText(video))",url: video.url,offerVideo: video) {
                            revoke(videoID: video.id)
                        }
                        if video.expiresAt != nil {
                            Button("„\(video.title)“ dauerhaft behalten") { keep(video) }.buttonStyle(.pill).disabled(busy)
                        }
                    }
                }
            }.frame(minHeight: 250)
            Text(message).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).textSelection(.enabled)
            Button("Aktualisieren") { Task { await reload() } }.disabled(busy)
        }.padding(24).frame(width: 940,height: 560).background(StudioTheme.background)
        .task { await reload() }
        .sheet(item: $offerVideo) { video in VideoOfferForm(videoID: video.id,title: video.title,expiresAt: video.expiresAt).environmentObject(store) }
        .sheet(isPresented: $offers) { VideoOffersView(activity: store.shareActivity).environmentObject(store) }
    }
    private func shareRow(title: String,detail: String,url: URL,offerVideo: SharedVideo? = nil,revoke: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading,spacing: 2) {
                Text(title).font(StudioFont.heading).lineLimit(1)
                Text(detail).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
            }
            Spacer()
            if supportsOffers,let offerVideo { Button("Angebot") { self.offerVideo = offerVideo }.buttonStyle(.pill) }
            Button("Kopieren") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString,forType: .string); message = "Link kopiert" }.buttonStyle(.pill)
            Button("Öffnen") { NSWorkspace.shared.open(url) }.buttonStyle(.pill)
            Button("Deaktivieren",role: .destructive,action: revoke).buttonStyle(.pill).disabled(busy || !lifecycle)
        }.padding(12).studioInset(padding: 0)
    }
    private func reload() async {
        busy = true; defer { busy = false }
        do {
            let client = try await store.shareClient()
            let status = try await client.status(); lifecycle = status.features.contains("guide-lifecycle-v2"); supportsOffers = status.supportsOffers
            if supportsOffers { await store.shareActivity.refresh() }
            videos = try await client.videos(); guides = try await client.guides()
            if lifecycle { store.guides.reconcileShares(guides,client: client) }
            if let receipt = store.shareReceipt, !videos.contains(where: { $0.id == receipt.video.id }),receipt.video.url.host == client.baseURL.host,receipt.video.url.port == client.baseURL.port {
                if let directory = store.directory { try FileManager.default.removeItem(at: directory.appendingPathComponent("share.json")) }
                store.shareReceipt = nil
            }
            message = lifecycle ? "\(videos.count) Videos · \(guides.count) Anleitungslinks" : "Server aktualisieren: Sicherer Widerruf benötigt guide-lifecycle-v2."
        } catch { message = error.localizedDescription }
    }
    private func revoke(guideID: String? = nil,videoID: String? = nil) {
        let impact = ShareRevocation(guideID: guideID,videoID: videoID,guides: guides)
        let alert = NSAlert(); alert.messageText = "Freigaben deaktivieren?"; alert.informativeText = impact.description(guides: guides)+"\n\nAußerdem werden \(store.shareActivity.offers.filter { impact.videoIDs.contains($0.videoId) }.count) Angebotslinks gesperrt und ihre Statistiken gelöscht."
        alert.addButton(withTitle: "Freigaben deaktivieren"); alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task {
            do {
                let client = try await store.shareClient()
                if let guideID { try await client.revokeGuide(guideID) }
                else if let videoID { try await client.revoke(videoID) }
                await reload(); message = "Freigaben deaktiviert. Bereits heruntergeladene Kopien bleiben beim Empfänger."
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    private func expiryText(_ video: SharedVideo) -> String {
        guard let date = video.expiryDate else { return "dauerhaft" }
        return "läuft ab am \(date.formatted(date: .numeric,time: .omitted))"
    }
    private func keep(_ video: SharedVideo) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let updated = try await store.shareClient().setExpiry(video.id,expiresAt: nil)
                if let i = videos.firstIndex(where: { $0.id == video.id }) { videos[i] = updated }
                message = "Link bleibt dauerhaft"
            } catch { message = error.localizedDescription }
        }
    }
}
