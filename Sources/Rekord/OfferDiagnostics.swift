import AppKit
import SwiftUI
import RecorderCore
import UserNotifications

/// Synthetic loopback acceptance only; never reads or uploads a user's recordings.
@MainActor enum OfferDiagnostics {
    static func run(arguments: [String]) async {
        guard let i = arguments.firstIndex(of: "--offer-diagnostics"),arguments.count > i+2 else { return }
        let root = URL(fileURLWithPath: arguments[i+2]); try? FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        var log: [String] = []
        do {
            struct Connection: Decodable { let baseURL: URL; let token: String }
            let c = try JSONDecoder().decode(Connection.self,from: Data(contentsOf: URL(fileURLWithPath: arguments[i+1])))
            guard ["localhost","127.0.0.1"].contains(c.baseURL.host ?? ""),UserDefaults.standard.string(forKey: "shareServer") == c.baseURL.absoluteString else { throw ShareError.message("Diagnostic requires an isolated loopback server argument.") }
            let api = try ShareClient(baseURL: c.baseURL,token: c.token)
            let video = try await api.upload(file: root.appendingPathComponent("synthetic-120.mp4"),title: "Synthetische Angebotsdemo")
            var draft = OfferDraft(videoId: video.id,title: "Dein nächster Schritt",bookingURL: "https://example.test/termin")
            draft.recipientLabel = "Beispielagentur"; draft.message = "So könnte unsere Zusammenarbeit aussehen."
            let offer = try await api.createOffer(draft)
            let store = EditorStore(meetingsRoot: root.appendingPathComponent("Meetings"),guidesRoot: root.appendingPathComponent("Guides"))
            let center = UNUserNotificationCenter.current(),permission = await center.notificationSettings()
            let canNotify = permission.authorizationStatus == .authorized
            store.shareActivity.client = { api }; store.shareActivity.notificationsEnabled = canNotify
            await store.shareActivity.refresh()
            store.shareActivity.start(allowDiagnostic: true)
            defer { store.shareActivity.stop() }
            var request = URLRequest(url: c.baseURL.appendingPathComponent("api/offers/\(offer.id)/sessions")); request.httpMethod = "POST"
            request.setValue("application/json",forHTTPHeaderField: "Content-Type"); request.setValue(c.baseURL.absoluteString,forHTTPHeaderField: "Origin"); request.httpBody = Data(#"{"measurementMode":"automatic-v1"}"#.utf8)
            let (_,response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw ShareError.message("Synthetic session failed.") }
            let began = Date()
            while !store.shareActivity.activity.contains(where: { $0.offerId == offer.id }),Date().timeIntervalSince(began) < 30 { try await Task.sleep(nanoseconds: 250_000_000) }
            guard store.shareActivity.activity.contains(where: { $0.offerId == offer.id }) else { throw ShareError.message("15-second polling failed.") }
            log.append("PASS live polling: opening visible after \(Int(Date().timeIntervalSince(began))) seconds")
            if canNotify,let event = store.shareActivity.activity.first(where: { $0.offerId == offer.id }) {
                let identifier = "offer-"+event.id
                try await Task.sleep(nanoseconds: 500_000_000)
                let delivered = await center.deliveredNotifications()
                guard delivered.contains(where: { $0.request.identifier == identifier }) else { throw ShareError.message("Authorized system notification was not delivered.") }
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                log.append("PASS authorized macOS notification delivered and synthetic notification removed")
            } else { log.append("SKIP system banner: macOS authorization not granted; no permission prompt triggered by diagnostics") }
            let restarted = ShareActivityStore(); restarted.client = { api }; restarted.notificationsEnabled = false; await restarted.refresh()
            guard restarted.activity.contains(where: { $0.offerId == offer.id }) else { throw ShareError.message("Restart lost activity.") }
            log.append("PASS activity survives recreated native store")
            let delegate = AppDelegate()
            delegate.handleNotification(["offer":offer.id,"offerServer":c.baseURL.absoluteString]); delegate.attach(store)
            guard store.showVideoOffers,store.shareActivity.selectedID == offer.id else { throw ShareError.message("Deferred offer navigation failed.") }
            store.showVideoOffers = false; delegate.handleNotification(["offer":offer.id,"offerServer":c.baseURL.absoluteString])
            guard store.showVideoOffers else { throw ShareError.message("Offer navigation failed.") }
            delegate.handleNotification(["meeting":root.path])
            guard !store.showVideoOffers,store.workspace == .meetings else { throw ShareError.message("Meeting navigation regressed.") }
            log.append("PASS offer navigation before/after attachment and meeting routing")
            SnapshotDiagnostics.active = true; defer { SnapshotDiagnostics.active = false }
            await SnapshotDiagnostics.snapshot(VideoOfferForm(videoID: video.id,title: offer.title,existing: offer).environmentObject(store),size: CGSize(width: 620,height: 640),to: root.appendingPathComponent("native-form.png"))
            await SnapshotDiagnostics.snapshot(VideoOffersView(activity: store.shareActivity).environmentObject(store),size: CGSize(width: 940,height: 640),to: root.appendingPathComponent("native-offers.png"))
            var template = OfferTemplate(); template.bookingURL = "https://example.test/termin"; template.landingPage.sender = "Beispielagentur"; template.landingPage.accent = "blue"; template.message = "Lass uns über dein Projekt sprechen."
            await SnapshotDiagnostics.snapshot(OfferSetupView(template: template).environmentObject(store),size: CGSize(width: 850,height: 610),to: root.appendingPathComponent("native-setup.png"))
            log.append("PASS native setup, form and offer detail snapshots")
            try await api.revoke(video.id)
        } catch { log.append("FAIL \(error.localizedDescription)") }
        try? log.joined(separator: "\n").write(to: root.appendingPathComponent("native-report.txt"),atomically: true,encoding: .utf8)
    }
}
