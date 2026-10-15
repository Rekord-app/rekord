import AppKit
import Foundation
import CryptoKit
import RecorderCore

extension EditorStore {
    func shareClient(server: URL? = nil) throws -> ShareClient {
        let address = server?.absoluteString ?? UserDefaults.standard.string(forKey: "shareServer") ?? ""
        guard let url = URL(string: address),let token = try ShareKeychain.read(server: address) else { throw ShareError.message("Bitte zuerst deinen Share-Server einrichten.") }
        return try ShareClient(baseURL: url,token: token)
    }
    func loadShareReceipt(directory: URL) {
        shareReceipt = try? JSONDecoder().decode(ShareReceipt.self,from: Data(contentsOf: directory.appendingPathComponent("share.json")))
    }
    /// Shares the open project. `expected` pins the project a command asked for: if anything else is open, nothing is shared.
    func share(expected: URL? = nil,commandID: String? = nil) {
        guard phase == .idle,let project,let directory else { return }
        if let expected, ExportTarget.canonical(expected).path != ExportTarget.canonical(directory).path {
            reportCommand(id: commandID,action: "share",error: "Falsches Projekt geöffnet, Freigabe abgebrochen."); return
        }
        guard shareConfigured else { showShareSettings = true; status = "Aufnahme lokal gesichert · Share-Server einrichten, um einen Link zu erstellen"; return }
        pause(); phase = .exporting; exportProgress = 0; status = "Link wird vorbereitet …"
        shareTask = Task {
            defer { phase = .idle; shareTask = nil }
            do {
                let client = try shareClient(), limits = try await client.status()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let fingerprint = try project.fingerprint()
                let movie = directory.appendingPathComponent("share.mp4"), marker = directory.appendingPathComponent("share-export.txt")
                let cached = (try? String(contentsOf: marker,encoding: .utf8)) == fingerprint && FileManager.default.fileExists(atPath: movie.path)
                if !cached {
                    let realtime = directory.appendingPathComponent("loom.mov")
                    let liveFingerprint = try? String(contentsOf: directory.appendingPathComponent("loom-project.txt"),encoding: .utf8)
                    if liveFingerprint == fingerprint && FileManager.default.fileExists(atPath: realtime.path) {
                        try await MovieExporter.prepareQuickShare(project: project,directory: directory,to: movie)
                    } else {
                        try await MovieExporter.export(project: project,directory: directory,to: movie,height: 1080,fps: project.defaultExportFPS,
                                                       maxBitRate: project.recordingMode == .loom ? MovieExporter.loomBitRate : nil) { progress in
                            Task { @MainActor in self.exportProgress = progress }
                        }
                    }
                    try fingerprint.write(to: marker,atomically: true,encoding: .utf8)
                }
                try Task.checkCancellation()
                let size = (try FileManager.default.attributesOfItem(atPath: movie.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size <= limits.maxUploadBytes else { throw ShareError.message("Die Aufnahme überschreitet das Upload-Limit oder den verfügbaren Videospeicher.") }
                phase = .uploading; exportProgress = 0; status = "Aufnahme wird hochgeladen …"
                let video = try await client.upload(file: movie,title: project.name,expiresInDays: Self.shareExpiryDays) { progress in Task { @MainActor in self.exportProgress = progress } }
                let receipt = ShareReceipt(video: video,server: client.baseURL,projectHash: fingerprint)
                try encoder.encode(receipt).write(to: directory.appendingPathComponent("share.json"),options: .atomic)
                shareReceipt = receipt; copyShareLink(); status = "Bereit zum Teilen · Link in die Zwischenablage kopiert"
                if commandID != nil { reportCommand(id: commandID,action: "share",link: video.url.absoluteString,done: true) }
            } catch is CancellationError { status = "Freigabe abgebrochen · Aufnahme bleibt lokal erhalten"; if commandID != nil { reportCommand(id: commandID,action: "share",error: "Freigabe abgebrochen.") } }
            catch let error as URLError where error.code == .cancelled { status = "Freigabe abgebrochen · Aufnahme bleibt lokal erhalten"; if commandID != nil { reportCommand(id: commandID,action: "share",error: "Freigabe abgebrochen.") } }
            catch { self.error = error.localizedDescription; status = "Freigabe fehlgeschlagen · Erneut teilen setzt bei der fertigen MP4 fort"; if commandID != nil { reportCommand(id: commandID,action: "share",error: error.localizedDescription) } }
        }
    }
    func cancelShare() { shareTask?.cancel() }
    /// Days until new video links expire on the server (nil = never). Default 90 days, see Settings → Teilen.
    static var shareExpiryDays: Int? {
        let days = UserDefaults.standard.object(forKey: "shareExpiryDays") as? Int ?? 90
        return days > 0 ? days : nil
    }
    func copyShareLink() {
        guard let url = shareReceipt?.video.url else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString,forType: .string)
        status = "Link kopiert"
    }
    func openShareLink() { if let url = shareReceipt?.video.url { NSWorkspace.shared.open(url) } }
    func revokeShare() {
        guard phase == .idle,let receipt = shareReceipt,let directory else { return }
        phase = .uploading; status = "Link wird deaktiviert …"
        shareTask = Task {
            defer { phase = .idle; shareTask = nil }
            do {
                try await shareClient(server: receipt.server).revoke(receipt.video.id)
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("share.json"))
                shareReceipt = nil; status = "Freigabelink deaktiviert · Lokales Projekt bleibt erhalten"
            } catch { self.error = error.localizedDescription }
        }
    }
}
