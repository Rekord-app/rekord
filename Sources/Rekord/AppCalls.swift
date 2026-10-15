import AppKit
import RecorderCore

/// `rekord://call` operations for the MCP server: everything in the app that needs its running state, the share
/// token in the Keychain, the Claude key or a confirmation dialog. Arguments arrive in the key-protected request
/// file (AppCall); the result goes back the same way. Secrets (Claude key, share token, server) are never read
/// or changed here, nor are switches that need someone's consent (automatic meeting recording, team inventory).
extension EditorStore {
    func performCall(_ command: AppCommand) {
        guard let op = command.op, let id = command.id else { return }
        let arguments: [String: Any]
        do { arguments = try AppCall.readRequest(id: id,op: op) } catch {
            AppCall.writeResult(id: id,result: nil,error: error.localizedDescription); reportCommand(command,error: error.localizedDescription); return
        }
        Task {
            do {
                let result = try await runCall(op,CallArguments(values: arguments))
                AppCall.writeResult(id: id,result: result,error: nil); reportCommand(id: id,action: "call:\(op)")
            } catch {
                AppCall.writeResult(id: id,result: nil,error: error.localizedDescription); reportCommand(id: id,action: "call:\(op)",error: error.localizedDescription)
            }
        }
    }

    func runCall(_ op: String,_ a: CallArguments) async throws -> [String: Any] {
        switch op {
        // MARK: Library
        case "library.create_folder":
            let folder = try Library.createFolder(try a.string("name"),in: libraryRoot); refreshLibrary()
            return ["folder": folder.lastPathComponent,"path": folder.path]
        case "library.rename_folder":
            let folder = try userFolder(a.string("folder")), inside = Library.projects(directlyIn: folder)
            if let locked = inside.first(where: { lockReason($0) != nil }) { throw CallError("\(RecordingInfo.title(locked)): \(lockReason(locked) ?? "")") }
            let target = try Library.renameFolder(folder,to: try a.string("name"))
            moved(inside.map { ($0,target.appendingPathComponent($0.lastPathComponent)) })
            if folderFilter == folder.lastPathComponent { folderFilter = target.lastPathComponent }
            refreshLibrary(); return ["folder": target.lastPathComponent,"path": target.path]
        case "library.dissolve_folder":
            let folder = try userFolder(a.string("folder"))
            if let locked = Library.projects(directlyIn: folder).first(where: { lockReason($0) != nil }) { throw CallError("\(RecordingInfo.title(locked)): \(lockReason(locked) ?? "")") }
            let result = try Library.dissolveFolder(folder,into: libraryRoot)
            moved(result.map { ($0.from,$0.to) })
            if folderFilter == folder.lastPathComponent { folderFilter = nil }
            refreshLibrary(); return ["moved": result.map { $0.to.path }]
        case "library.move":
            let url = try recording(a)
            if let reason = lockReason(url) { throw CallError(reason) }
            let target = try a.optionalString("folder").map { try userFolder($0) } ?? libraryRoot
            let new = try Library.move(url,to: target)
            moved([(url,new)]); refreshLibrary()
            return ["recording": new.path,"folder": Library.folder(of: new,root: libraryRoot) as Any]
        case "library.trash":
            let url = try recording(a)
            guard a.bool("confirm") == true else { throw CallError("Zum Löschen confirm: true mitgeben.") }
            if let reason = lockReason(url) { throw CallError(reason) }
            if directory?.standardizedFileURL.path == url.standardizedFileURL.path { closeProject() }
            try Library.trash(url)
            recent.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }
            UserDefaults.standard.set(recent.map(\.path),forKey: "recentProjects")
            refreshLibrary(); return ["trashed": url.path,"hint": "Im Finder aus dem Papierkorb wiederherstellbar."]
        case "library.forget_recent":
            removeFromRecent(try recording(a)); return ["recent": recent.map(\.path)]

        // MARK: Recorder
        case "recorder.devices":
            refreshDevices(); return recorderSettings()
        case "recorder.configure":
            guard phase == .idle, countdown == nil else { throw CallError("Während einer Aufnahme lässt sich die Einrichtung nicht ändern.") }
            refreshDevices()
            if let mode = try a.optionalString("mode") {
                guard let value = RecordingMode(rawValue: mode) else { throw CallError("mode: studio oder loom") }
                chooseMode(value)
            }
            if let fps = try a.optionalInt("fps") { guard [30,60].contains(fps) else { throw CallError("fps: 30 oder 60") }; captureFPS = fps }
            if let value = a.bool("camera") { withCamera = value }
            if let value = a.bool("microphone") { withMicrophone = value }
            if let value = a.bool("system_audio") { withAudio = value }
            if let value = a.bool("countdown") { countdownEnabled = value }
            if let value = a.bool("auto_widescreen") { autoWidescreen = value }
            if let title = try a.optionalString("title") { recordingTitle = String(title.prefix(120)) }
            if let name = try a.optionalString("camera_device") { cameraID = try device(name,in: cameras,kind: "Kamera").id }
            if let name = try a.optionalString("microphone_device") { microphoneID = try device(name,in: microphones,kind: "Mikrofon").id }
            devicesChanged(); updateMonitor()
            return recorderSettings()
        case "recorder.discard":
            guard phase == .recording else { throw CallError("Es läuft keine Aufnahme.") }
            guard a.bool("confirm") == true else { throw CallError("Zum Verwerfen confirm: true mitgeben. Die laufende Aufnahme wird gelöscht.") }
            discardRecording(); return ["discarded": true]
        case "recorder.restart":
            guard phase == .recording else { throw CallError("Es läuft keine Aufnahme.") }
            guard a.bool("confirm") == true else { throw CallError("Zum Neustarten confirm: true mitgeben. Die bisherige Aufnahme wird gelöscht.") }
            restartRecording(); return ["restarted": true]

        // MARK: Sharing
        case "shares.list":
            let client = try await shareClient(), status = try await client.status()
            let videos = try await client.videos()
            let lifecycle = status.features.contains("guide-lifecycle-v2")
            let guideLinks = lifecycle ? try await client.guides() : []
            var receipts: [String: String] = [:]
            for url in library { if let receipt = try? JSONDecoder().decode(ShareReceipt.self,from: Data(contentsOf: url.appendingPathComponent("share.json"))) { receipts[receipt.video.id] = url.path } }
            var result: [String: Any] = [
                "videos": videos.map { v in ["video_id": v.id,"url": v.url.absoluteString,"title": v.title,"bytes": v.bytes,"created_at": v.createdAt,"expires_at": v.expiresAt as Any,"recording": receipts[v.id] as Any] },
                "guide_links": guideLinks.map { ["guide_id": $0.id,"url": $0.url.absoluteString,"title": $0.title,"video_id": $0.videoId as Any,"created_at": $0.createdAt] },
                "offers_supported": status.supportsOffers]
            if status.supportsOffers { result["offers"] = try await allOffers(client).map(offerJSON) }
            return result
        case "shares.set_expiry":
            let id = try a.string("video_id"), client = try await shareClient()
            let days = try a.optionalInt("days")
            if let days { guard (1...3650).contains(days) else { throw CallError("days: 1–3650 oder null (dauerhaft)") } }
            let video = try await client.setExpiry(id,expiresAt: days.map { Date().addingTimeInterval(Double($0)*86400) })
            return ["video_id": video.id,"url": video.url.absoluteString,"expires_at": video.expiresAt as Any]
        case "shares.revoke":
            let client = try await shareClient()
            let videoID = try a.optionalString("video_id"), guideID = try a.optionalString("guide_id")
            guard (videoID == nil) != (guideID == nil) else { throw CallError("Genau eins angeben: video_id oder guide_id.") }
            let sharedGuides = (try? await client.guides()) ?? []
            let impact = ShareRevocation(guideID: guideID,videoID: videoID,guides: sharedGuides)
            let offers = (try? await client.status().supportsOffers) == true ? try await allOffers(client).filter { impact.videoIDs.contains($0.videoId) } : []
            let summary: [String: Any] = ["videos": Array(impact.videoIDs),"guide_links": Array(impact.guideIDs),"offers": offers.map(\.id),"description": impact.description(guides: sharedGuides)]
            guard a.bool("confirm") == true else { return ["needs_confirm": true,"impact": summary,"hint": "Mit confirm: true deaktivieren. Empfänger können die Links danach nicht mehr öffnen."] }
            if let guideID { try await client.revokeGuide(guideID) } else if let videoID { try await client.revoke(videoID) }
            if let active = try? await client.guides() { guides.reconcileShares(active,client: client) }
            for url in library {
                let file = url.appendingPathComponent("share.json")
                if let receipt = try? JSONDecoder().decode(ShareReceipt.self,from: Data(contentsOf: file)), impact.videoIDs.contains(receipt.video.id) {
                    try? FileManager.default.removeItem(at: file)
                    if url.standardizedFileURL == directory?.standardizedFileURL { shareReceipt = nil }
                }
            }
            await shareActivity.refresh()
            return ["revoked": summary]

        // MARK: Video offers
        case "offers.list":
            return ["offers": try await allOffers(try await shareClient()).map(offerJSON)]
        case "offers.create":
            let client = try await shareClient()
            guard try await client.status().supportsOffers else { throw CallError("Der Share-Server unterstützt Video-Angebote noch nicht.") }
            var videoID = try a.optionalString("video_id")
            if videoID == nil, let path = try a.optionalString("recording") {
                let url = URL(fileURLWithPath: path).appendingPathComponent("share.json")
                guard let receipt = try? JSONDecoder().decode(ShareReceipt.self,from: Data(contentsOf: url)) else { throw CallError("Die Aufnahme ist noch nicht geteilt. Erst share_link aufrufen.") }
                videoID = receipt.video.id
            }
            guard let videoID else { throw CallError("recording oder video_id angeben.") }
            // Starts from the saved offer template (booking link, message, landing page), like the form in the app.
            var draft = OfferTemplate.load().draft(videoID: videoID,title: try a.string("title"))
            try fill(&draft,a)
            let offer = try await client.createOffer(draft)
            await shareActivity.refresh()
            var result = offerJSON(offer)
            if offer.notifyOnFirstOpen && !shareActivity.notificationsEnabled { result["hint"] = "Öffnungsmeldungen sind auf diesem Mac aus (settings: offer_notifications)." }
            return result
        case "offers.update":
            let client = try await shareClient(), id = try a.string("offer_id")
            guard let existing = try await allOffers(client).first(where: { $0.id == id }) else { throw CallError("Angebot \(id) nicht gefunden.") }
            var draft = OfferDraft(videoId: existing.videoId,title: try a.optionalString("title") ?? existing.title,bookingURL: existing.bookingURL.absoluteString)
            draft.recipientLabel = existing.recipientLabel; draft.message = existing.message
            draft.trackingEnabled = existing.trackingEnabled; draft.notifyOnFirstOpen = existing.notifyOnFirstOpen
            draft.trackingMode = existing.trackingMode; draft.landingPage = existing.landingPage
            try fill(&draft,a)
            let offer = try await client.updateOffer(id,draft: draft); await shareActivity.refresh()
            return offerJSON(offer)
        case "offers.stats":
            let client = try await shareClient(), id = try a.string("offer_id")
            var analytics = try await client.offerAnalytics(id), sessions = analytics.entries
            while analytics.hasMore, sessions.count < 2000 { analytics = try await client.offerAnalytics(id,after: analytics.nextCursor); sessions += analytics.entries }
            let summary = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(analytics.summary))) ?? [:]
            let entries = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(sessions))) ?? []
            return ["offer_id": id,"duration_s": analytics.durationSeconds,"summary": summary,"sessions": entries]
        case "offers.set_expiry":
            let id = try a.string("offer_id"), days = try a.optionalInt("days")
            if let days { guard (1...3650).contains(days) else { throw CallError("days: 1–3650 oder null (dauerhaft)") } }
            let offer = try await shareClient().setOfferExpiry(id,date: days.map { Date().addingTimeInterval(Double($0)*86400) })
            await shareActivity.refresh(); return offerJSON(offer)
        case "offers.revoke","offers.clear_stats":
            let id = try a.string("offer_id")
            guard a.bool("confirm") == true else { throw CallError(op == "offers.revoke" ? "Zum Sperren des Angebotslinks confirm: true mitgeben. Seine Statistik wird mit gelöscht." : "Zum Löschen der Statistik confirm: true mitgeben.") }
            let client = try await shareClient()
            if op == "offers.revoke" { try await client.revokeOffer(id) } else { try await client.clearOfferAnalytics(id) }
            await shareActivity.refresh(); return ["offer_id": id,"done": true]

        // MARK: Meetings
        case "meeting.start":
            guard !meetings.recording else { throw CallError("Es läuft schon ein Meeting.") }
            guard !busy, guides.phase == .idle else { throw CallError("Rekord nimmt gerade etwas anderes auf.") }
            showMeetings(); bringMainWindowForward()
            // The app asks for confirmation first (as with the shortcut); declined = nothing is recorded.
            meetings.start(title: try a.optionalString("title") ?? "",contact: try a.optionalString("contact") ?? "",company: try a.optionalString("company") ?? "")
            if let error = meetings.error { meetings.error = nil; throw CallError(error) }
            return ["recording": meetings.recording,"hint": meetings.recording ? "Läuft. meeting stop beendet und erstellt Transkript und Zusammenfassung." : "In der App nicht bestätigt, es wird nichts aufgenommen."]
        case "meeting.stop":
            guard meetings.recording else { throw CallError("Es läuft kein Meeting.") }
            meetings.stop(); return ["stopped": true,"hint": "Transkript und Zusammenfassung entstehen jetzt; list_meetings zeigt sie in etwa einer Minute."]
        case "meeting.discard":
            guard meetings.phase == .recording else { throw CallError("Es läuft kein Meeting.") }
            guard a.bool("confirm") == true else { throw CallError("Zum Verwerfen confirm: true mitgeben. Der laufende Call wird nicht gespeichert.") }
            meetings.discard(); return ["discarded": true]
        case "meeting.regenerate":
            let url = try meeting(a)
            guard meetings.phase == .idle else { throw CallError("Meetings sind gerade beschäftigt.") }
            meetings.retry(url,retranscribe: a.bool("retranscribe") ?? false)
            return ["started": true,"meeting": url.path,"hint": "get_meeting zeigt das neue Ergebnis, sobald es fertig ist."]
        case "meeting.ask":
            let url = try meeting(a), question = try a.string("question")
            guard ClaudeKeychain.hasKey else { throw CallError("Für Fragen an den Call braucht Rekord einen Claude-Schlüssel (Meetings → Einstellungen).") }
            meetings.error = nil
            await meetings.ask(url,question: question)
            if let error = meetings.error { meetings.error = nil; throw CallError(error) }
            guard let last = MeetingQuestion.load(from: url).last else { throw CallError("Keine Antwort erhalten.") }
            return ["question": last.question,"answer": last.answer]
        case "meeting.delete":
            let url = try meeting(a)
            guard a.bool("confirm") == true else { throw CallError("Zum Löschen confirm: true mitgeben. Ton, Transkript und Zusammenfassung gehen in den Papierkorb.") }
            try FileManager.default.trashItem(at: url,resultingItemURL: nil)
            if meetings.selected == url { meetings.selected = nil }
            meetings.reload(); return ["trashed": url.path]

        // MARK: Guides
        case "guide.start":
            guard guides.phase == .idle else { throw CallError("Es läuft schon eine Anleitung.") }
            guard !busy, !meetings.recording else { throw CallError("Rekord nimmt gerade etwas anderes auf.") }
            showGuides(); guides.start(); return ["started": true]
        case "guide.stop":
            guard guides.recording else { throw CallError("Es läuft keine Anleitung.") }
            guides.stop(); return ["stopped": true,"hint": "Schritte und Bilder entstehen jetzt; list_guides zeigt die Anleitung danach."]
        case "guide.edit":
            return try await editGuide(try guide(a),a)
        case "guide.rewrite","guide.rebuild","guide.brief":
            let url = try guide(a)
            guard guides.phase == .idle else { throw CallError("Anleitungen sind gerade beschäftigt.") }
            if op != "guide.rebuild", !ClaudeKeychain.hasKey { throw CallError("Dafür braucht Rekord einen Claude-Schlüssel (Meetings → Einstellungen).") }
            switch op {
            case "guide.rewrite": guides.rewriteTexts(url)
            case "guide.rebuild": guides.rebuild(url)
            default:
                if let frequency = a.number("frequency_per_week"),let guide = guides.load(url) { try guides.setFrequency(frequency,for: guide,url: url) }
                guides.writeBrief(url)
            }
            return ["started": true,"guide": url.path,"hint": "get_guide zeigt das Ergebnis, sobald es fertig ist."]
        case "guide.share":
            let url = try guide(a)
            guard guides.phase == .idle, let guide = guides.load(url) else { throw CallError("Anleitung ist gerade beschäftigt oder nicht lesbar.") }
            let shared = try await GuideSharing.upload(guide: guide,directory: url,client: try await shareClient())
            guides.revision += 1
            return ["url": shared.url.absoluteString,"guide_id": shared.id]
        case "guide.revoke":
            let url = try guide(a)
            guard let record = GuideSharing.record(in: url) else { throw CallError("Diese Anleitung ist nicht geteilt.") }
            let client = try await shareClient(); try await client.requireGuideLifecycle()
            let active = try await client.guides()
            let impact = ShareRevocation(guideID: record.guideID,guides: active)
            guard a.bool("confirm") == true else { return ["needs_confirm": true,"description": impact.description(guides: active),"hint": "Mit confirm: true deaktivieren."] }
            try await client.revokeGuide(record.guideID)
            guides.reconcileShares(try await client.guides(),client: client)
            return ["revoked": Array(impact.guideIDs)]
        case "guide.delete":
            let url = try guide(a)
            guard a.bool("confirm") == true else { throw CallError("Zum Löschen confirm: true mitgeben. Video, Schritte und Bilder gehen in den Papierkorb.") }
            guard !(guides.recording) else { throw CallError("Während einer Anleitungsaufnahme nicht möglich.") }
            try FileManager.default.trashItem(at: url,resultingItemURL: nil)
            if guides.selected == url { guides.selected = nil }
            guides.reload(); return ["trashed": url.path]

        // MARK: Inventory
        case "inventory.start":
            inventory.start()
            return ["phase": inventory.phase.rawValue,"hint": inventory.phase == .off ? "Im Team-Modus muss die Zustimmung in der App bestätigt werden." : "Läuft."]
        case "inventory.stop":
            inventory.stop(); return ["phase": inventory.phase.rawValue]
        case "inventory.pause":
            guard inventory.phase != .off else { throw CallError("Die Inventur läuft nicht.") }
            if a.bool("until_tomorrow") == true { inventory.pauseUntilTomorrow() } else {
                let minutes = try a.optionalInt("minutes") ?? 15
                guard (1...1440).contains(minutes) else { throw CallError("minutes: 1–1440") }
                inventory.pause(minutes: minutes)
            }
            return ["phase": inventory.phase.rawValue]
        case "inventory.resume":
            inventory.resume(); return ["phase": inventory.phase.rawValue]
        case "inventory.exclude":
            let app = try a.string("app").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !app.isEmpty, app.count <= 200, !app.contains("\n") else { throw CallError("app: Bundle-ID oder App-Name") }
            let current = inventory.exclusions.split(separator: "\n").map(String.init)
            if !current.contains(app) { inventory.exclusions += (inventory.exclusions.isEmpty ? "" : "\n")+app }
            return ["exclusions": inventory.exclusions.split(separator: "\n").map(String.init)]
        case "inventory.analyze":
            guard !inventory.processing else { throw CallError("Die Auswertung läuft schon.") }
            Task { await inventory.buildCatalog() }
            return ["started": true,"hint": "list_processes zeigt den neuen Katalog, sobald die Auswertung fertig ist."]

        // MARK: Storage
        case "storage.status":
            let folder = libraryRoot, usage = Storage.usage(folder)
            let plan = Storage.plan(Storage.scan(folder),policy: Self.storagePolicy,protected: storageProtected)
            return ["usage_bytes": ["studio": usage.studio,"loom": usage.loom,"meetings": usage.meetings,"guides": usage.guides,
                                    "inventory_images": usage.inventoryImages,"inventory_samples": usage.inventorySamples,"total": usage.total,"free_on_disk": usage.freeOnDisk],
                    "usage": ["total": Storage.format(usage.total),"free_on_disk": Storage.format(usage.freeOnDisk)],
                    "policy": policyJSON(Self.storagePolicy),
                    "cleanup_preview": plan.map(actionJSON)]
        case "storage.cleanup":
            let plan = Storage.plan(Storage.scan(libraryRoot),policy: Self.storagePolicy,protected: storageProtected)
            guard a.bool("confirm") == true else { return ["needs_confirm": true,"would": plan.map(actionJSON),"hint": "Mit confirm: true ausführen."] }
            guard phase == .idle else { throw CallError("Während Aufnahme oder Export wird nicht aufgeräumt.") }
            cleanUpStorage(manual: true); return ["done": plan.map(actionJSON),"status": status]

        // MARK: Settings
        case "settings.get":
            return settingsJSON()
        case "settings.set":
            try applySettings(a); return settingsJSON()
        default:
            throw CallError("Unbekannte Operation: \(op)")
        }
    }

    // MARK: Helpers

    private func recording(_ a: CallArguments) throws -> URL {
        let url = URL(fileURLWithPath: try a.string("recording")).standardizedFileURL
        guard ProjectFolder.isProject(url), FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) else { throw CallError("Aufnahme nicht gefunden: \(url.path)") }
        // Only recordings of this library (or opened from the archive and listed under Zuletzt).
        let known = { self.library.contains { $0.standardizedFileURL.path == url.path } || self.recent.contains { $0.standardizedFileURL.path == url.path } }
        if !known() { refreshLibrary() }
        guard known() else { throw CallError("Die Aufnahme gehört nicht zur Rekord-Bibliothek: \(url.path)") }
        return url
    }
    private func userFolder(_ name: String) throws -> URL {
        guard let folder = Library.folders(in: libraryRoot).first(where: { $0.lastPathComponent == name || $0.path == name }) else { throw CallError("Ordner „\(name)“ nicht gefunden.") }
        return folder
    }
    private func meeting(_ a: CallArguments) throws -> URL {
        let url = URL(fileURLWithPath: try a.string("meeting")).standardizedFileURL
        guard MeetingsFolder.isMeeting(url), url.deletingLastPathComponent().standardizedFileURL.path == meetings.root.standardizedFileURL.path else { throw CallError("Meeting nicht gefunden: \(url.path)") }
        guard !(meetings.recording && url.standardizedFileURL == meetings.directory?.standardizedFileURL) else { throw CallError("Dieses Meeting läuft gerade.") }
        return url
    }
    private func guide(_ a: CallArguments) throws -> URL {
        let url = URL(fileURLWithPath: try a.string("guide")).standardizedFileURL
        guard GuidesFolder.isGuide(url), url.deletingLastPathComponent().standardizedFileURL.path == guides.root.standardizedFileURL.path else { throw CallError("Anleitung nicht gefunden: \(url.path)") }
        return url
    }
    private func device(_ value: String,in list: [CaptureDeviceOption],kind: String) throws -> CaptureDeviceOption {
        if value.isEmpty { return CaptureDeviceOption(id: "",name: "Standard") }
        if let match = list.first(where: { $0.id == value }) ?? list.first(where: { $0.name.localizedCaseInsensitiveContains(value) }) { return match }
        throw CallError("\(kind) „\(value)“ nicht gefunden. Verfügbar: \(list.map(\.name).joined(separator: ", "))")
    }
    private func recorderSettings() -> [String: Any] {
        ["mode": recordingMode.rawValue,"fps": captureFPS,"camera": withCamera,"microphone": withMicrophone,"system_audio": withAudio,
         "countdown": countdownEnabled,"auto_widescreen": autoWidescreen,"title": recordingTitle,
         "camera_device": cameras.first { $0.id == cameraID }?.name ?? "Standard","microphone_device": microphones.first { $0.id == microphoneID }?.name ?? "Standard",
         "cameras": cameras.map { ["id": $0.id,"name": $0.name] },"microphones": microphones.map { ["id": $0.id,"name": $0.name] },
         "phase": "\(phase)","recorder_open": hudActive]
    }
    private func allOffers(_ client: ShareClient) async throws -> [VideoOffer] {
        var page = try await client.offers(), offers = page.offers
        while page.hasMore, offers.count < 1000 { page = try await client.offers(after: page.nextCursor); offers += page.offers }
        return offers
    }
    private func offerJSON(_ offer: VideoOffer) -> [String: Any] {
        ["offer_id": offer.id,"url": offer.url.absoluteString,"video_id": offer.videoId,"title": offer.title,"recipient": offer.recipientLabel,"message": offer.message,
         "booking_url": offer.bookingURL.absoluteString,"tracking": offer.trackingEnabled,"tracking_mode": offer.trackingMode as Any,"notify_on_first_open": offer.notifyOnFirstOpen,
         "landing_page": offer.landingPage.map { ["sender": $0.sender,"button_title": $0.buttonTitle,"accent": $0.accent] } as Any,
         "created_at": offer.createdAt,"expires_at": offer.expiresAt as Any,"duration_s": offer.durationSeconds,
         "summary": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(offer.summary))) ?? [:]]
    }
    private func fill(_ draft: inout OfferDraft,_ a: CallArguments) throws {
        if let value = try a.optionalString("title") { draft.title = value }
        if let value = try a.optionalString("booking_url") { draft.bookingURL = value }
        if let value = try a.optionalString("tracking_mode") { guard ["automatic","consent"].contains(value) else { throw CallError("tracking_mode: automatic oder consent") }; draft.trackingMode = value }
        if a.values.keys.contains(where: { ["sender","button_title","accent"].contains($0) }) {
            var page = draft.landingPage ?? OfferLandingPage()
            if let value = try a.optionalString("sender") { page.sender = value }
            if let value = try a.optionalString("button_title") { page.buttonTitle = value }
            if let value = try a.optionalString("accent") { page.accent = value }
            draft.landingPage = page
        }
        if let value = try a.optionalString("recipient") { draft.recipientLabel = value }
        if let value = try a.optionalString("message") { draft.message = value }
        if let value = a.bool("tracking") { draft.trackingEnabled = value }
        if let value = a.bool("notify_on_first_open") { draft.notifyOnFirstOpen = value }
        try draft.validate()
    }
    private func editGuide(_ url: URL,_ a: CallArguments) async throws -> [String: Any] {
        guard guides.phase == .idle || guides.phase == .recording, var guide = guides.load(url) else { throw CallError("Anleitung ist nicht lesbar.") }
        var images = a.bool("regenerate_images") ?? false
        func index(_ value: Any?) throws -> Int {
            guard let n = (value as? NSNumber)?.intValue, n >= 1, n <= guide.steps.count else { throw CallError("Schritt muss zwischen 1 und \(guide.steps.count) liegen.") }
            return n-1
        }
        if let title = try a.optionalString("title") { guard !title.isEmpty else { throw CallError("title darf nicht leer sein.") }; guide.title = String(title.prefix(200)) }
        if let summary = try a.optionalString("summary") { guide.summary = summary.isEmpty ? nil : summary }
        if let value = a.bool("call_to_action") { guide.showCallToAction = value }
        for item in a.values["steps"] as? [[String: Any]] ?? [] {
            let i = try index(item["step"])
            if let text = item["text"] as? String { guide.steps[i].text = text }
            if let note = item["note"] as? String { guide.steps[i].note = note.isEmpty ? nil : note }
            if let warning = item["warning"] as? String { guide.steps[i].warning = warning.isEmpty ? nil : warning }
        }
        for item in a.values["add_redactions"] as? [[String: Any]] ?? [] {
            let i = try index(item["step"])
            guard let x = (item["x"] as? NSNumber)?.doubleValue, let y = (item["y"] as? NSNumber)?.doubleValue,
                  let w = (item["width"] as? NSNumber)?.doubleValue, let h = (item["height"] as? NSNumber)?.doubleValue,
                  [x,y,w,h].allSatisfy(\.isFinite), w > 0.004, h > 0.004 else { throw CallError("Schwärzung: x, y, width, height als Anteil 0–1 des Bildes.") }
            guide.steps[i].redactions.append(GuideRedaction(rect: GuideRect(x: x,y: y,width: w,height: h).clipped(),reason: "manual")); images = true
        }
        for item in a.values["remove_redactions"] as? [[String: Any]] ?? [] {
            let i = try index(item["step"])
            guard let id = item["id"] as? String, guide.steps[i].redactions.contains(where: { $0.id == id }) else { throw CallError("Schwärzung in Schritt \(i+1) nicht gefunden (id aus get_guide).") }
            guide.steps[i].redactions.removeAll { $0.id == id }; images = true
        }
        if let item = a.values["merge_with_next"] { let i = try index(item); guard i+1 < guide.steps.count else { throw CallError("Der letzte Schritt hat keinen nächsten.") }
            let next = guide.steps.remove(at: i+1); guide.steps[i].text += " "+next.text; guide.steps[i].redactions += next.redactions.filter { $0.reason == "manual" }; images = true }
        if let move = a.values["move_step"] as? [String: Any] {
            let from = try index(move["from"]), to = try index(move["to"])
            guide.steps.insert(guide.steps.remove(at: from),at: to); images = true
        }
        let deletions = try (a.values["delete_steps"] as? [Any] ?? []).map { try index($0) }
        for i in Set(deletions).sorted(by: >) { guide.steps.remove(at: i); images = true }
        guard !guide.steps.isEmpty else { throw CallError("Eine Anleitung braucht mindestens einen Schritt.") }
        if images { try await GuideImages.generate(&guide,in: url) }
        try guides.persist(guide,at: url); guides.revision += 1
        return ["guide": url.path,"title": guide.title,"steps": guide.steps.count,"images_regenerated": images]
    }
    private func policyJSON(_ policy: Storage.Policy) -> [String: Any] {
        ["loom_trash_days": policy.loomTrashDays as Any,"studio_archive_days": policy.studioArchiveDays as Any,"archive_folder": policy.archiveFolder as Any]
    }
    private func actionJSON(_ action: Storage.Action) -> [String: Any] {
        switch action {
        case .trash(let item): return ["action": "trash","recording": item.url.path,"bytes": item.bytes]
        case .archive(let item,let folder): return ["action": "archive","recording": item.url.path,"to": folder.path,"bytes": item.bytes]
        }
    }
    private func settingsJSON() -> [String: Any] {
        let d = UserDefaults.standard
        let template = OfferTemplate.load()
        return ["share_expiry_days": d.object(forKey: "shareExpiryDays") as? Int ?? 90,"offer_booking_url": template.bookingURL,"offer_message": template.message,
                "offer_sender": template.landingPage.sender,"offer_button_title": template.landingPage.buttonTitle,"offer_accent": template.landingPage.accent,"offer_template_ready": template.isConfigured,
                "offer_notifications": shareActivity.notificationsEnabled,"guide_address": guides.address.rawValue,"hourly_rate": guides.hourlyRate,
                "meeting_own_name": meetings.ownName,"meeting_glossary": meetings.glossary,"meeting_show_controller": meetings.showController,"launch_at_login": meetings.launchAtLogin,
                "countdown": countdownEnabled,"auto_widescreen": autoWidescreen,"storage": policyJSON(Self.storagePolicy),
                "inventory": ["questions_per_day": inventory.questionsPerDay,"token_budget": inventory.tokenBudget,"image_days": inventory.imageDays,
                              "sample_days": inventory.sampleDays,"catalog_time": String(format: "%02d:%02d",inventory.catalogHour,inventory.catalogMinute)],
                "not_available_here": "Claude-Schlüssel, Share-Server und -Token, automatische Meeting-Aufnahme und Team-Inventur nur in der App (Einwilligung bzw. Geheimnisse)."]
    }
    private func applySettings(_ a: CallArguments) throws {
        let d = UserDefaults.standard
        if let days = try a.optionalInt("share_expiry_days") { guard [0,7,30,90,365].contains(days) else { throw CallError("share_expiry_days: 7, 30, 90, 365 oder 0 (nie)") }; d.set(days,forKey: "shareExpiryDays") }
        if a.values.keys.contains(where: { $0.hasPrefix("offer_") && $0 != "offer_notifications" }) {
            // The offer template as in „Angebote einrichten“: saved only when complete (HTTPS booking link).
            var template = OfferTemplate.load()
            if let value = try a.optionalString("offer_booking_url") { template.bookingURL = value }
            if let value = try a.optionalString("offer_message") { template.message = value }
            if let value = try a.optionalString("offer_sender") { template.landingPage.sender = value }
            if let value = try a.optionalString("offer_button_title") { template.landingPage.buttonTitle = value }
            if let value = try a.optionalString("offer_accent") { template.landingPage.accent = value }
            try template.save()
        }
        if let value = try a.optionalString("guide_address") { guard let address = GuideAddress(rawValue: value) else { throw CallError("guide_address: du oder sie") }; guides.address = address }
        if let rate = a.number("hourly_rate") { guard (1...10000).contains(rate) else { throw CallError("hourly_rate: 1–10000") }; guides.hourlyRate = rate }
        if let name = try a.optionalString("meeting_own_name") { meetings.ownName = String(name.prefix(80)) }
        if let glossary = try a.optionalString("meeting_glossary") { meetings.glossary = String(glossary.prefix(4000)) }
        if let value = a.bool("launch_at_login") { meetings.setLaunchAtLogin(value) }
        if let value = a.bool("meeting_show_controller") { meetings.showController = value }
        if let value = a.bool("countdown") { countdownEnabled = value }
        if let value = a.bool("auto_widescreen") { autoWidescreen = value }
        if a.values.keys.contains(where: { $0.hasPrefix("storage_") }) {
            var policy = Self.storagePolicy
            if a.values.keys.contains("storage_loom_trash_days") { policy.loomTrashDays = try a.optionalInt("storage_loom_trash_days").map { d in guard (1...3650).contains(d) else { throw CallError("storage_loom_trash_days: 1–3650 oder null") }; return d } }
            if a.values.keys.contains("storage_studio_archive_days") { policy.studioArchiveDays = try a.optionalInt("storage_studio_archive_days").map { d in guard (1...3650).contains(d) else { throw CallError("storage_studio_archive_days: 1–3650 oder null") }; return d } }
            if a.values.keys.contains("storage_archive_folder") {
                let path = try a.optionalString("storage_archive_folder")
                if let path, !path.isEmpty {
                    var isDirectory: ObjCBool = false
                    guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path,isDirectory: &isDirectory), isDirectory.boolValue else { throw CallError("storage_archive_folder muss ein vorhandener Ordner sein.") }
                    policy.archiveFolder = path
                } else { policy.archiveFolder = nil }
            }
            Self.storagePolicy = policy
        }
        if let value = try a.optionalInt("inventory_questions_per_day") { guard (0...15).contains(value) else { throw CallError("inventory_questions_per_day: 0–15") }; inventory.questionsPerDay = value }
        if let value = try a.optionalInt("inventory_token_budget") { guard (0...5_000_000).contains(value) else { throw CallError("inventory_token_budget: 0–5000000") }; inventory.tokenBudget = value }
        if let value = try a.optionalInt("inventory_image_days") { guard (1...365).contains(value) else { throw CallError("inventory_image_days: 1–365") }; inventory.imageDays = value }
        if let value = try a.optionalInt("inventory_sample_days") { guard (1...365).contains(value) else { throw CallError("inventory_sample_days: 1–365") }; inventory.sampleDays = value }
        if let value = try a.optionalString("inventory_catalog_time") {
            let parts = value.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { throw CallError("inventory_catalog_time: HH:MM") }
            inventory.catalogHour = parts[0]; inventory.catalogMinute = parts[1]
        }
        if let value = a.bool("offer_notifications") { Task { await shareActivity.enableNotifications(value) } }
    }
}

struct CallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Typed access to the JSON arguments of a call; wrong types are errors, not silent defaults.
struct CallArguments {
    let values: [String: Any]
    func string(_ key: String) throws -> String {
        guard let value = try optionalString(key) else { throw CallError("\(key) fehlt.") }
        return value
    }
    func optionalString(_ key: String) throws -> String? {
        guard let raw = values[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else { throw CallError("\(key) muss Text sein.") }
        return value
    }
    func optionalInt(_ key: String) throws -> Int? {
        guard let raw = values[key], !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue, abs(number.doubleValue) < 1e9 else { throw CallError("\(key) muss eine ganze Zahl sein.") }
        return number.intValue
    }
    func number(_ key: String) -> Double? { (values[key] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil } }
    func bool(_ key: String) -> Bool? {
        guard let number = values[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
