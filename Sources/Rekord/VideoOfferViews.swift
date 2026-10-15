import SwiftUI
import RecorderCore

struct VideoOfferForm: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) var dismiss
    let existing: VideoOffer?
    let expiresAt: String?
    @State private var draft: OfferDraft
    @State private var busy = false
    @State private var message = ""
    @State private var saved: VideoOffer?
    @State private var attempted: OfferDraft?
    @State private var setup = false
    init(videoID: String,title: String,existing: VideoOffer? = nil,expiresAt: String? = nil) {
        self.existing = existing; self.expiresAt = existing?.expiresAt ?? expiresAt
        var d = OfferTemplate.load().draft(videoID: videoID,title: title)
        if let existing { d.title = existing.title; d.recipientLabel = existing.recipientLabel; d.message = existing.message; d.bookingURL = existing.bookingURL.absoluteString; d.trackingEnabled = existing.trackingEnabled; d.notifyOnFirstOpen = existing.notifyOnFirstOpen; d.trackingMode = existing.trackingMode; d.landingPage = existing.landingPage }
        _draft = State(initialValue: d)
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack { Text(existing == nil ? "Video-Angebot teilen" : "Angebot bearbeiten").font(StudioFont.pageTitle); Spacer(); Button("Schließen") { dismiss() }.buttonStyle(.pill).disabled(busy) }
            Text("Ein eigener Link für diesen Empfänger. Das Video bleibt unverändert.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
            Form {
                TextField("Empfänger (nur intern)",text: $draft.recipientLabel)
                TextField("Öffentlicher Titel",text: $draft.title)
                TextField("Nachricht (optional)",text: $draft.message,axis: .vertical).lineLimit(3...5)
                TextField("Buchungslink",text: $draft.bookingURL).help("Vollständiger HTTPS-Link zu deinem Buchungssystem")
                DisclosureGroup("Landingpage und Statistik anpassen") {
                    OfferLandingFields(page: Binding(get: { draft.landingPage ?? OfferLandingPage() },set: { draft.landingPage = $0 }))
                    Toggle("Statistik aktiv",isOn: $draft.trackingEnabled)
                    Toggle("Bei erster Öffnung benachrichtigen",isOn: $draft.notifyOnFirstOpen).disabled(!draft.trackingEnabled)
                    Picker("Messung",selection: Binding(get: { draft.trackingMode ?? "consent" },set: { draft.trackingMode = $0 })) {
                        Text("Automatisch").tag("automatic"); Text("Nach Zustimmung").tag("consent")
                    }.disabled(!draft.trackingEnabled)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).frame(height: 340).disabled(busy || saved != nil)
            Text("Verfügbar bis: \(expiresAt.map { String($0.prefix(10)) } ?? "dauerhaft")").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
            Text(draft.trackingEnabled ? (draft.trackingMode == "automatic" ? "Statistik ist automatisch aktiv. Besucher können sie ausschalten. Ein Link bestätigt keine Identität." : "Statistik nach Zustimmung des Besuchers. Ein Link bestätigt keine Identität.") : "Statistik ist für dieses Angebot ausgeschaltet.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary).fixedSize(horizontal: false,vertical: true)
            if !message.isEmpty { Text(message).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                if existing == nil && saved == nil { Button("Standardvorlage …") { setup = true }.buttonStyle(.pill).disabled(busy) }
                Spacer()
                if let saved {
                    if existing == nil { Button("Weiterer Empfänger") { self.saved = nil; attempted = nil; draft.creationRequestId = UUID().uuidString; draft.recipientLabel = ""; message = "" }.buttonStyle(.pill) }
                    Button("Link kopieren") { copyOffer(saved) }.buttonStyle(.pill)
                    Button("Vorschau") { Task { do { NSWorkspace.shared.open(try await store.shareClient().offerPreview(saved.id)) } catch { message = error.localizedDescription } } }.buttonStyle(.pill)
                } else {
                    Button(existing == nil ? "Angebotslink erstellen" : "Änderungen speichern") { submit() }.buttonStyle(AccentButtonStyle(height: 34)).disabled(busy)
                }
            }
        }.padding(24).frame(width: 620).background(StudioTheme.background)
        .sheet(isPresented: $setup) { OfferSetupView {
            let value = OfferTemplate.load(); draft.bookingURL = value.bookingURL; draft.message = value.message; draft.landingPage = value.landingPage
        }.environmentObject(store) }
        .onAppear { if existing == nil && !OfferTemplate.load().isConfigured { setup = true } }
    }
    private func copyOffer(_ offer: VideoOffer) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(offer.url.absoluteString,forType: .string); message = "Angebotslink kopiert · \(offer.url.absoluteString)" }
    private func submit() {
        busy = true; message = "Angebot wird gespeichert …"
        Task {
            defer { busy = false }
            do {
                let api = try store.shareClient()
                guard try await api.status().supportsOffers else { throw ShareError.message("Server unterstützt Video-Angebote noch nicht.") }
                try draft.validate()
                // Keep identical retries idempotent; an edited failed request needs a fresh identity.
                if let attempted,attempted != draft { draft.creationRequestId = UUID().uuidString }
                attempted = draft
                let result: VideoOffer
                if let existing { result = try await api.updateOffer(existing.id,draft: draft) } else { result = try await api.createOffer(draft) }
                saved = result; copyOffer(result)
                if draft.notifyOnFirstOpen && !store.shareActivity.notificationsEnabled { await store.shareActivity.enableNotifications(true) }
                await store.shareActivity.refresh()
            } catch { message = error.localizedDescription+" · Du kannst erneut versuchen." }
        }
    }
}

struct VideoOffersView: View {
    @EnvironmentObject var store: EditorStore
    @ObservedObject var activity: ShareActivityStore
    @Environment(\.dismiss) var dismiss
    @State private var editing: VideoOffer?
    @State private var removing: VideoOffer?
    @State private var setup = false
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            HStack {
                VStack(alignment: .leading,spacing: 4) { Text("Video-Angebote").font(StudioFont.pageTitle); Text("Aktivität über deine persönlichen Links").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary) }
                Spacer()
                if activity.loading { ProgressView().controlSize(.small) }
                Button("Buchungslink & Landingpage") { setup = true }.buttonStyle(.pill)
                Button("Aktualisieren") { Task { await activity.refresh() } }.buttonStyle(.pill)
                Button("Fertig") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top,spacing: 16) {
                ScrollView {
                    LazyVStack(alignment: .leading,spacing: 8) {
                        ForEach(activity.offers) { offer in
                            Button { activity.selectedID = offer.id } label: {
                                VStack(alignment: .leading,spacing: 5) {
                                    Text(offer.label).font(StudioFont.heading).foregroundStyle(StudioTheme.text)
                                    Text(offer.title).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                                    Text(offer.summary.openings == 0 ? "Noch keine gemessene Aktivität" : "\(offer.summary.openings) Öffnungen · \(Int(offer.summary.bestPercent)) % abgespielt").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                                }.frame(maxWidth: .infinity,alignment: .leading).padding(12).background(activity.selectedID == offer.id ? StudioTheme.accent.opacity(0.12) : StudioTheme.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(width: 260)
                if let offer = activity.offers.first(where: { $0.id == activity.selectedID }) {
                    OfferDetail(offer: offer,editing: { editing = offer },removing: { removing = offer }).id(offer.id)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "paperplane").font(.system(size: 38)).foregroundStyle(StudioTheme.accent)
                        Text("Deine Video-Angebote").font(StudioFont.title)
                        Text("Hinterlege deinen Buchungslink und die Landingpage. Danach teilst du ein Video als Angebot – die Statistik startet automatisch.").font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 390)
                        Button("Buchungslink & Landingpage einrichten") { setup = true }.buttonStyle(AccentButtonStyle(height: 36))
                    }.frame(maxWidth: .infinity,maxHeight: .infinity)
                }
            }
            Text(activity.message).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
        }.padding(24).frame(width: 940,height: 640).background(StudioTheme.background)
        .task { await activity.refresh(); if activity.selectedID == nil { activity.selectedID = activity.offers.first?.id } }
        .sheet(isPresented: $setup) { OfferSetupView().environmentObject(store) }
        .sheet(item: $editing) { offer in VideoOfferForm(videoID: offer.videoId,title: offer.title,existing: offer).environmentObject(store) }
        .confirmationDialog("Diesen Angebotslink deaktivieren?",isPresented: Binding(get: { removing != nil },set: { if !$0 { removing = nil } })) {
            Button("Angebotslink deaktivieren",role: .destructive) {
                guard let offer = removing else { return }; removing = nil
                Task { do { try await store.shareClient().revokeOffer(offer.id); await activity.refresh() } catch { activity.message = error.localizedDescription } }
            }
        } message: { Text("Andere Angebote desselben Videos bleiben verfügbar. Die Statistik dieses Links wird gelöscht.") }
    }
}
private struct OfferDetail: View {
    @EnvironmentObject var store: EditorStore
    let offer: VideoOffer
    let editing: () -> Void
    let removing: () -> Void
    @State private var stats: OfferAnalytics?
    @State private var sessions: [OfferSession] = []
    @State private var message = ""
    @State private var clear = false
    @State private var busy = false
    @State private var editExpiry = false
    @State private var expires = true
    @State private var expiryDate = Date().addingTimeInterval(30*86400)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 14) {
                Text(offer.label).font(StudioFont.title)
                Text("Zuordnung über diesen Link, keine bestätigte Person.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                HStack {
                    Button("Link kopieren") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(offer.url.absoluteString,forType: .string); message = "Link kopiert" }.buttonStyle(.pill)
                    Button("Vorschau") { Task { do { NSWorkspace.shared.open(try await store.shareClient().offerPreview(offer.id)) } catch { message = error.localizedDescription } } }.buttonStyle(.pill)
                    Button("Bearbeiten",action: editing).buttonStyle(.pill)
                }
                let summary = stats?.summary ?? offer.summary
                Text(!offer.trackingEnabled ? "Statistik ausgeschaltet" : summary.state == "limited" ? "Messlimit erreicht" : summary.state == "damaged" ? "Statistik beschädigt – bitte zurücksetzen" : summary.openings == 0 ? "Noch keine gemessene Aktivität" : "\(summary.openings) Öffnungen · \(summary.started) Wiedergaben gestartet").font(StudioFont.heading)
                Text("Beste Wiedergabe: \(Int(summary.bestPercent)) % · \(clock(summary.bestPlayedSeconds)) von \(clock(offer.durationSeconds))").font(StudioFont.body)
                ProgressView(value: min(100,max(0,summary.bestPercent)),total: 100)
                Text("Terminbutton \(summary.ctaClickCount)× geklickt · keine bestätigten Buchungen").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                Text("Laufzeit: \(offer.expiresAt.map(date) ?? "dauerhaft") · Messdaten bis zu \(summary.retentionDays) Tage").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
                if let first = store.shareActivity.activity.first(where: { $0.offerId == offer.id }) {
                    Text("Erste gemessene Öffnung: \(date(first.openedAt))").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                }
                if let last = summary.lastActivityAt { Text("Letzte Aktivität: \(date(last))").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary) }
                Button("Laufzeit ändern") {
                    expires = offer.expiresAt != nil
                    if let value = offer.expiresAt { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; expiryDate = f.date(from: value) ?? expiryDate }
                    editExpiry = true
                }.buttonStyle(.pill)
                Text("Wiedergabe-Sessions").eyebrow()
                ForEach(sessions) { s in
                    VStack(alignment: .leading,spacing: 3) {
                        Text("\(date(s.openedAt)) · \(Int(s.percent)) % abgespielt").font(StudioFont.captionStrong)
                        Text("Zuletzt abgespielt bis \(clock(s.lastPosition)) · Terminbutton \(s.ctaClickCount)× · synchronisiert \(date(s.lastActivityAt))").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                    }.frame(maxWidth: .infinity,alignment: .leading).padding(10).studioInset(padding: 0)
                }
                if stats?.hasMore == true { Button("Weitere Sessions laden") { load(more: true) }.buttonStyle(.pill).disabled(busy) }
                HStack { Button("Statistik aktualisieren") { load() }.buttonStyle(.pill); Button("Statistik löschen",role: .destructive) { clear = true }.buttonStyle(.pill) }
                Button("Angebotslink deaktivieren",role: .destructive,action: removing).buttonStyle(.pill)
                if !message.isEmpty { Text(message).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary) }
            }.frame(maxWidth: .infinity,alignment: .leading).padding(.trailing,4)
        }.onAppear { load() }
        .onChange(of: offer.summary.lastActivityAt) { load() }
        .sheet(isPresented: $editExpiry) {
            VStack(alignment: .leading,spacing: 16) {
                Text("Laufzeit des Angebots").font(StudioFont.title)
                Toggle("Angebotslink läuft ab",isOn: $expires)
                if expires { DatePicker("Verfügbar bis",selection: $expiryDate,in: Date()...).datePickerStyle(.field) }
                Text("Ein Angebot kann höchstens so lange verfügbar sein wie das zugehörige Video. Dessen Laufzeit änderst du bei den geteilten Aufnahmen.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                Text(message).font(StudioFont.caption)
                HStack { Button("Abbrechen") { editExpiry = false }; Spacer(); Button("Speichern") { Task { do { _ = try await store.shareClient().setOfferExpiry(offer.id,date: expires ? expiryDate : nil); editExpiry = false; await store.shareActivity.refresh() } catch { message = error.localizedDescription } } } }
            }.padding(24).frame(width: 460)
        }
        .confirmationDialog("Statistik dieses Angebots endgültig löschen?",isPresented: $clear) {
            Button("Statistik löschen",role: .destructive) { Task { do { try await store.shareClient().clearOfferAnalytics(offer.id); load(); await store.shareActivity.refresh() } catch { message = error.localizedDescription } } }
        } message: { Text("Video und Angebotslink bleiben erhalten. Bestehende Mess-Sessions werden beendet.") }
    }
    private func load(more: Bool = false) {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; do { let value = try await store.shareClient().offerAnalytics(offer.id,after: more ? stats?.nextCursor ?? "" : ""); stats = value; sessions = more ? sessions+value.entries : value.entries; message = "" } catch { message = error.localizedDescription } }
    }
    private func clock(_ seconds: Double) -> String { let n = Int(max(0,seconds)); return String(format: "%d:%02d",n/60,n%60) }
    private func date(_ value: String) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return (f.date(from: value) ?? ISO8601DateFormatter().date(from: value))?.formatted(date: .abbreviated,time: .shortened) ?? value }
}
