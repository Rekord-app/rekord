import AppKit
import SwiftUI
import UserNotifications
import RecorderCore
import CryptoKit

@MainActor final class ShareActivityStore: ObservableObject {
    @Published var offers: [VideoOffer] = []
    @Published var activity: [OfferActivity] = []
    @Published var message = ""
    @Published var lastSync: Date?
    @Published var supported = false
    @Published var loading = false
    @Published var selectedID: String?
    @Published var notificationsEnabled = UserDefaults.standard.bool(forKey: "offerNotifications")
    var client: (() throws -> ShareClient)?
    private var task: Task<Void,Never>?
    private var wakeObserver: NSObjectProtocol?
    private var configuredServer = ""
    private var failures = 0
    func start(allowDiagnostic: Bool = false) {
        guard task == nil,allowDiagnostic || !CommandLine.arguments.contains("--exit-after-diagnostics") else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,object: nil,queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                let delay = min(300,15*pow(2,Double(failures)))
                try? await Task.sleep(nanoseconds: UInt64(delay*1_000_000_000))
            }
        }
    }
    func stop() {
        task?.cancel(); task = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
    }
    func cursorKey(_ server: String) -> String {
        "offerCursor."+SHA256.hash(data: Data(server.utf8)).map { String(format: "%02x",$0) }.joined()
    }
    func enableNotifications(_ value: Bool) async {
        if value {
            // Initialize the cursor before enabling banners, so old history never causes a storm.
            await refresh()
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.sound])
                notificationsEnabled = granted
                if !granted { message = "macOS-Mitteilungen sind aus. Die Aktivität bleibt hier sichtbar." }
            } catch { message = error.localizedDescription; notificationsEnabled = false }
        } else { notificationsEnabled = false }
        UserDefaults.standard.set(notificationsEnabled,forKey: "offerNotifications")
    }
    func refresh() async {
        guard !loading,let client else { return }
        // No Keychain prompts before a server is configured, or in diagnostic app instances.
        guard !(UserDefaults.standard.string(forKey: "shareServer") ?? "").isEmpty else { offers = []; activity = []; supported = false; message = "Bitte zuerst den Share-Server einrichten."; return }
        loading = true; defer { loading = false }
        do {
            let api = try client(),server = api.baseURL.absoluteString
            if configuredServer != server { offers = []; activity = []; supported = false; configuredServer = server; lastSync = nil }
            supported = try await api.status().supportsOffers
            guard supported else { message = "Dieser Server unterstützt Video-Angebote noch nicht. Normales Teilen bleibt verfügbar."; failures = 0; return }
            var all: [VideoOffer] = [], after = ""
            repeat {
                let page = try await api.offers(after: after); all += page.offers
                guard page.hasMore else { break }; guard page.nextCursor > after else { throw ShareError.message("Ungültige Angebots-Paginierung.") }; after = page.nextCursor
            } while all.count <= 10000
            offers = all.sorted { $0.createdAt > $1.createdAt }
            // Fetch full retained history for the activity list; no sensitive history persisted on the Mac.
            var events: [OfferActivity] = []; after = ""
            repeat {
                let page = try await api.offerActivity(after: after); events += page.entries
                guard page.hasMore else { break }; guard page.nextCursor > after else { throw ShareError.message("Ungültige Aktivitäts-Paginierung.") }; after = page.nextCursor
            } while events.count <= 10000
            activity = events.sorted { $0.cursor > $1.cursor }
            let key = cursorKey(server),old = UserDefaults.standard.string(forKey: key),batch = OfferNotificationBatch(previousCursor: old,activities: events)
            // Advance even if notifications are disabled: enabling later should not send historical banners.
            UserDefaults.standard.set(batch.cursor,forKey: key)
            if notificationsEnabled,!batch.notifications.isEmpty { await notify(batch.notifications,server: server) }
            lastSync = Date(); failures = 0; message = offers.isEmpty ? "Noch keine Video-Angebote." : "\(offers.count) Video-Angebote · zuletzt synchronisiert \(Date().formatted(date: .omitted,time: .shortened))"
        } catch { failures = min(5,failures+1); message = "Server nicht erreichbar: \(error.localizedDescription)" }
    }
    private func notify(_ events: [OfferActivity],server: String) async {
        let content = UNMutableNotificationContent()
        content.title = events.count == 1 ? "Video-Angebot geöffnet" : "\(events.count) Video-Angebote geöffnet"
        if let event = events.first {
            content.body = events.count == 1 ? "Aktivität über deinen Link für \(event.recipientLabel.isEmpty ? event.title : event.recipientLabel)." : "Neue Aktivität ist in Rekord verfügbar."
            content.userInfo = ["offer":event.offerId,"offerServer":server]
            content.sound = .default
            do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "offer-"+event.id,content: content,trigger: nil)) }
            catch { message = "Aktivität gespeichert; macOS-Mitteilung konnte nicht angezeigt werden." }
        }
    }
}
