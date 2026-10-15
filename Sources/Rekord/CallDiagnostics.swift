import AppKit
import RecorderCore

/// `--call-check <dir> --project <fixture.rekord> [--share-connection <connection.json>]`: every MCP app call
/// through the real path (key-protected request file → rekord://call → handler → result file) against copies of a
/// synthetic fixture in `<dir>`. With a loopback share harness also links, expiry, revoke and video offers.
/// Never touches the user's recordings, meetings, guides or share server; changed defaults are restored.
@MainActor enum CallDiagnostics {
    static func run(arguments: [String]) async {
        guard let i = arguments.firstIndex(of: "--call-check"),arguments.count > i+1,
              let p = arguments.firstIndex(of: "--project"),arguments.count > p+1 else { return }
        let root = URL(fileURLWithPath: arguments[i+1]), fixture = URL(fileURLWithPath: arguments[p+1])
        let connection = arguments.firstIndex(of: "--share-connection").flatMap { arguments.count > $0+1 ? URL(fileURLWithPath: arguments[$0+1]) : nil }
        try? FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        var lines: [String] = []
        func log(_ line: String) { lines.append(line); try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("call-report.txt"),atomically: true,encoding: .utf8) }
        let keys = ["recentProjects","countdown","offerTemplate","offerBookingURL"], saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key,value) in zip(keys,saved) { UserDefaults.standard.set(value,forKey: key) } }
        setenv("REKORD_SUPPORT_ROOT",root.appendingPathComponent("support").path,1)
        defer { unsetenv("REKORD_SUPPORT_ROOT") }
        do {
            try await check(root: root,fixture: fixture,connection: connection,log: log)
            log("PASS: app calls end to end")
        } catch { log("FAIL: \(error.localizedDescription)") }
    }

    private static func check(root: URL,fixture: URL,connection: URL?,log: (String) -> Void) async throws {
        let files = FileManager.default
        let library = root.appendingPathComponent("Bibliothek"), guidesRoot = root.appendingPathComponent("Anleitungen"), meetingsRoot = root.appendingPathComponent("Meetings")
        for dir in [library,guidesRoot,meetingsRoot,root.appendingPathComponent("support")] { try? files.removeItem(at: dir) }
        try files.createDirectory(at: library,withIntermediateDirectories: true)
        let a = library.appendingPathComponent("call-check-a.rekord"), b = library.appendingPathComponent("call-check-b.rekord")
        try files.copyItem(at: fixture,to: a); try files.copyItem(at: fixture,to: b)
        let meeting = try SnapshotFixtures.makeMeetings(in: meetingsRoot).first.unwrap("meeting fixture")
        let guide = try await makeGuide(in: guidesRoot,fixture: fixture)
        let store = EditorStore(captureRoot: library,meetingsRoot: meetingsRoot,guidesRoot: guidesRoot)
        store.recent = []; store.refreshLibrary(); store.guides.reload(); store.meetings.reload()

        /// One call through the full channel; returns the result or the refusal text.
        func call(_ op: String,_ arguments: [String: Any] = [:]) async throws -> (ok: Bool,result: [String: Any],error: String?) {
            let id = UUID().uuidString
            try AppCall.writeRequest(id: id,op: op,arguments: arguments)
            store.handleCommand(AppCall.url(op: op,id: id))
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                if let outcome = AppCall.takeResult(id: id) { return outcome }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw RecorderError.message("\(op): no answer")
        }
        func expect(_ op: String,_ arguments: [String: Any] = [:]) async throws -> [String: Any] {
            let outcome = try await call(op,arguments)
            guard outcome.ok else { throw RecorderError.message("\(op) failed: \(outcome.error ?? "?")") }
            return outcome.result
        }
        func refuse(_ op: String,_ arguments: [String: Any] = [:],_ why: String) async throws {
            let outcome = try await call(op,arguments)
            guard !outcome.ok else { throw RecorderError.message("\(op) must be refused: \(why)") }
        }
        func require(_ condition: Bool,_ message: String) throws { if !condition { throw RecorderError.message(message) } }

        // A URL without its request file (what a web page could send) does nothing.
        store.handleCommand(AppCall.url(op: "library.trash",id: "forged"))
        try await Task.sleep(nanoseconds: 300_000_000)
        try require(files.fileExists(atPath: a.path) && AppCall.takeResult(id: "forged")?.ok == false,"forged URL must be refused")

        // Library
        _ = try await expect("library.create_folder",["name": "Kunden"])
        try await refuse("library.create_folder",["name": "Meetings"],"reserved name")
        var moved = try await expect("library.move",["recording": a.path,"folder": "Kunden"])
        let aInFolder = URL(fileURLWithPath: moved["recording"] as? String ?? "")
        try require(files.fileExists(atPath: aInFolder.path) && Library.folder(of: aInFolder,root: library) == "Kunden","move into folder")
        store.open(b); try require(store.directory?.path == b.path,"open b")
        moved = try await expect("library.move",["recording": b.path,"folder": "Kunden"])
        let bInFolder = URL(fileURLWithPath: moved["recording"] as? String ?? "")
        try require(store.directory?.standardizedFileURL.path == bInFolder.standardizedFileURL.path && store.project != nil,"open project follows its move")
        _ = try await expect("library.rename_folder",["folder": "Kunden","name": "Kunden 2026"])
        let renamedB = library.appendingPathComponent("Kunden 2026").appendingPathComponent(b.lastPathComponent)
        try require(store.directory?.standardizedFileURL.path == renamedB.standardizedFileURL.path,"open project follows its folder rename")
        try await refuse("library.trash",["recording": renamedB.path],"no confirm")
        _ = try await expect("library.trash",["recording": renamedB.path,"confirm": true])
        try require(!files.fileExists(atPath: renamedB.path) && store.project == nil,"trash closes and removes the open take")
        try await refuse("library.move",["recording": fixture.path],"recording outside the library")
        _ = try await expect("library.dissolve_folder",["folder": "Kunden 2026"])
        try require(Library.folders(in: library).isEmpty && files.fileExists(atPath: a.path),"dissolve brings the take back")
        log("PASS: library – create (reserved refused), move, open take follows move and folder rename, trash needs confirm, foreign path refused, dissolve")

        // Guides
        let before = try Guide.load(from: guide)
        _ = try await expect("guide.edit",["guide": guide.path,"title": "Geprüfte Anleitung","steps": [["step": 1,"text": "Neuer Text","note": "Hinweis"]],
                                         "add_redactions": [["step": 1,"x": 0.1,"y": 0.1,"width": 0.3,"height": 0.1]]])
        var after = try Guide.load(from: guide)
        try require(after.title == "Geprüfte Anleitung" && after.steps[0].text == "Neuer Text" && after.steps[0].note == "Hinweis","guide text")
        try require(after.steps[0].redactions.count == before.steps[0].redactions.count+1,"redaction added")
        let redaction = after.steps[0].redactions.last!.id
        _ = try await expect("guide.edit",["guide": guide.path,"remove_redactions": [["step": 1,"id": redaction]],"delete_steps": [2]])
        after = try Guide.load(from: guide)
        try require(after.steps.count == before.steps.count-1 && !after.steps[0].redactions.contains { $0.id == redaction },"redaction removed, step deleted")
        try await refuse("guide.edit",["guide": guide.path,"delete_steps": Array(1...after.steps.count)],"empty guide")
        try await refuse("guide.edit",["guide": fixture.path,"title": "x"],"not a guide")
        log("PASS: guides – title/text/note, redaction add/remove with image regeneration, delete step, empty guide and foreign path refused")

        // Meetings
        try await refuse("meeting.delete",["meeting": meeting.path],"no confirm")
        _ = try await expect("meeting.delete",["meeting": meeting.path,"confirm": true])
        try require(!files.fileExists(atPath: meeting.path),"meeting trashed")
        try await refuse("meeting.stop",[:],"nothing running")
        log("PASS: meetings – delete needs confirm, stop without a call refused")

        // Recorder, storage, settings
        let devices = try await expect("recorder.devices")
        try require(devices["cameras"] is [Any] && devices["mode"] != nil,"devices")
        _ = try await expect("recorder.configure",["mode": "loom","title": "Call-Check"])
        try require(store.recordingMode == .loom && store.recordingTitle == "Call-Check","configure")
        try await refuse("recorder.configure",["mode": "vhs"],"bad mode")
        try await refuse("recorder.discard",["confirm": true],"nothing recording")
        let storage = try await expect("storage.status")
        try require(storage["usage_bytes"] != nil && storage["cleanup_preview"] is [Any],"storage status")
        let settings = try await expect("settings.get")
        let countdown = settings["countdown"] as? Bool ?? true
        _ = try await expect("settings.set",["countdown": !countdown])
        try require(store.countdownEnabled == !countdown,"settings set")
        try await refuse("settings.set",["share_expiry_days": 12],"invalid value")
        _ = try await expect("settings.set",["offer_booking_url": "https://example.test/termin","offer_message": "Hallo","offer_button_title": "Termin","offer_accent": "violet"])
        try require(OfferTemplate.load().landingPage.accent == "violet" && OfferTemplate.load().isConfigured,"offer template saved")
        try await refuse("settings.set",["offer_booking_url": "http://unsicher.test"],"template needs https")
        try await refuse("nope.op",[:],"unknown op")
        log("PASS: recorder devices/configure, storage status, settings get/set with validation, unknown op refused")

        // Sharing and offers against the loopback harness
        if let connection {
            struct Connection: Decodable { let baseURL: URL; let token: String }
            let c = try JSONDecoder().decode(Connection.self,from: Data(contentsOf: connection))
            try require(["127.0.0.1","localhost"].contains(c.baseURL.host ?? ""),"loopback only")
            let api = try ShareClient(baseURL: c.baseURL,token: c.token)
            store.shareClientOverride = api; store.shareActivity.client = { api }
            let mp4 = root.appendingPathComponent("call-check.mp4"); try? files.removeItem(at: mp4)
            try await MovieExporter.export(project: try Project.load(from: a),directory: a,to: mp4,height: 720,fps: 30)
            let video = try await api.upload(file: mp4,title: "Call-Check",expiresInDays: 30)
            var list = try await expect("shares.list")
            try require((list["videos"] as? [[String: Any]])?.contains { $0["video_id"] as? String == video.id } == true,"list shows the video")
            let kept = try await expect("shares.set_expiry",["video_id": video.id,"days": NSNull()])
            try require(kept["expires_at"] is NSNull || kept["expires_at"] == nil,"keep forever")
            let offer = try await expect("offers.create",["video_id": video.id,"title": "Dein nächster Schritt","recipient": "Beispiel GmbH","booking_url": "https://example.test/termin",
                                                         "tracking_mode": "consent","sender": "Call-Check","button_title": "Gespräch buchen","accent": "blue","notify_on_first_open": false])
            try require(offer["tracking_mode"] as? String == "consent" && (offer["landing_page"] as? [String: Any])?["button_title"] as? String == "Gespräch buchen","landing page and tracking mode")
            try await refuse("offers.create",["video_id": video.id,"title": "x","booking_url": "https://example.test/t","accent": "pink"],"bad accent")
            let offerID = try (offer["offer_id"] as? String).unwrap("offer id")
            let updated = try await expect("offers.update",["offer_id": offerID,"message": "Kurz erklärt."])
            try require(updated["message"] as? String == "Kurz erklärt." && updated["recipient"] as? String == "Beispiel GmbH" && updated["tracking_mode"] as? String == "consent"
                        && (updated["landing_page"] as? [String: Any])?["accent"] as? String == "blue","update keeps other fields")
            _ = try await expect("offers.stats",["offer_id": offerID])
            _ = try await expect("offers.set_expiry",["offer_id": offerID,"days": 7])
            try await refuse("offers.revoke",["offer_id": offerID],"no confirm")
            _ = try await expect("offers.revoke",["offer_id": offerID,"confirm": true])
            let preview = try await expect("shares.revoke",["video_id": video.id])
            try require(preview["needs_confirm"] as? Bool == true,"revoke previews first")
            _ = try await expect("shares.revoke",["video_id": video.id,"confirm": true])
            list = try await expect("shares.list")
            try require((list["videos"] as? [[String: Any]])?.contains { $0["video_id"] as? String == video.id } == false,"revoked video gone")
            UserDefaults.standard.removeObject(forKey: store.shareActivity.cursorKey(api.baseURL.absoluteString))   // no loopback leftovers in the user's defaults
            log("PASS: sharing – list, keep forever, offer create/update/stats/expiry/revoke (confirm), video revoke previews then revokes")
        } else { log("SKIP: sharing (no --share-connection)") }

        // Leave nothing in the user's Trash.
        if let trash = try? files.url(for: .trashDirectory,in: .userDomainMask,appropriateFor: nil,create: false) {
            for item in (try? files.contentsOfDirectory(at: trash,includingPropertiesForKeys: nil)) ?? []
            where item.lastPathComponent.hasPrefix("call-check-") || item.lastPathComponent.hasPrefix("Kunden 2026") || item.lastPathComponent == meeting.lastPathComponent { try? files.removeItem(at: item) }
        }
    }

    /// A small guide on the fixture's screen video, so image regeneration runs for real.
    private static func makeGuide(in root: URL,fixture: URL) async throws -> URL {
        let directory = root.appendingPathComponent("call-check-guide")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("screen.mov"),to: directory.appendingPathComponent("screen.mov"))
        let steps = [1.0,1.8,2.4].enumerated().map { i,time in
            GuideStep(action: .click,text: "Schritt \(i+1)",element: nil,appName: "Finder",bundleID: "com.apple.finder",windowTitle: nil,url: nil,time: time,position: Point(0.3+0.1*Double(i),0.4))
        }
        var guide = Guide(title: "Call-Check",duration: 3,steps: steps)
        try await GuideImages.generate(&guide,in: directory)
        try guide.save(to: directory)
        return directory
    }
}

private extension Optional {
    func unwrap(_ what: String) throws -> Wrapped {
        guard let self else { throw RecorderError.message("missing \(what)") }
        return self
    }
}
