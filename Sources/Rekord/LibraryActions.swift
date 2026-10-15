import AppKit
import RecorderCore

/// Library management: folders, moving, renaming and deleting recordings. Everything happens in Finder folders
/// under the recordings folder, so the MCP server and Finder see the same structure.
extension EditorStore {
    var libraryRoot: URL { captureRoot ?? RecordingsFolder.url }

    func refreshLibrary() {
        let root = libraryRoot
        let found = Library.projects(in: root)
        let known = Set(found.map(\.standardizedFileURL.path))
        // Takes opened from elsewhere (e.g. the storage archive) stay listed while they are in the recent list.
        let outside = recent.filter {
            !known.contains($0.standardizedFileURL.path) && !Library.isTemporary($0)
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("project.json").path)
        }
        let all = found+outside, names = Library.folders(in: root)
        if all != library { library = all }
        if names != folders { folders = names }
        if let filter = folderFilter, !names.contains(where: { $0.lastPathComponent == filter }) { folderFilter = nil }
    }
    func recordings(inFolder name: String?) -> [URL] {
        guard let name else { return library }
        return library.filter { Library.folder(of: $0,root: libraryRoot) == name }
    }
    func folderName(of url: URL) -> String? { Library.folder(of: url,root: libraryRoot) }
    func showLibrary(folder: String?) {
        guard !busy else { return }
        folderFilter = folder; refreshLibrary(); showRecordingSetup()
    }
    /// Why a recording cannot move or go to the Trash right now; nil when it can.
    func lockReason(_ url: URL) -> String? {
        let key = url.standardizedFileURL.path
        if recordingDirectory?.standardizedFileURL.path == key { return "Wird gerade aufgenommen" }
        if exports.jobs.contains(where: { $0.directory.standardizedFileURL.path == key && ($0.state == .waiting || $0.state == .running) }) { return "Wird gerade exportiert" }
        if phase != .idle, directory?.standardizedFileURL.path == key { return "Wird gerade exportiert oder geteilt" }
        return nil
    }

    @discardableResult func createFolder(_ name: String) -> URL? {
        do {
            let folder = try Library.createFolder(name,in: libraryRoot)
            refreshLibrary(); status = "Ordner „\(folder.lastPathComponent)“ angelegt"
            return folder
        } catch { self.error = error.localizedDescription; return nil }
    }
    func renameFolder(_ folder: URL,to name: String) {
        let inside = Library.projects(directlyIn: folder)
        if let locked = inside.first(where: { lockReason($0) != nil }) { self.error = "„\(folder.lastPathComponent)“ kann gerade nicht umbenannt werden: \(lockReason(locked) ?? "")."; return }
        do {
            let target = try Library.renameFolder(folder,to: name)
            moved(inside.map { ($0,target.appendingPathComponent($0.lastPathComponent)) })
            if folderFilter == folder.lastPathComponent { folderFilter = target.lastPathComponent }
            refreshLibrary(); status = "Ordner heißt jetzt „\(target.lastPathComponent)“"
        } catch { self.error = error.localizedDescription }
    }
    /// The recordings go back to „Alle Aufnahmen“; nothing is deleted.
    func dissolveFolder(_ folder: URL) {
        if let locked = Library.projects(directlyIn: folder).first(where: { lockReason($0) != nil }) {
            self.error = "„\(folder.lastPathComponent)“ kann gerade nicht aufgelöst werden: \(lockReason(locked) ?? "")."; return
        }
        do {
            let result = try Library.dissolveFolder(folder,into: libraryRoot)
            moved(result.map { ($0.from,$0.to) })
            if folderFilter == folder.lastPathComponent { folderFilter = nil }
            refreshLibrary(); status = "Ordner „\(folder.lastPathComponent)“ aufgelöst · \(result.count) \(result.count == 1 ? "Aufnahme" : "Aufnahmen") wieder unter Alle Aufnahmen"
        } catch { self.error = error.localizedDescription }
    }
    /// Moves recordings into a user folder (nil = directly into the recordings folder).
    func move(_ urls: [URL],toFolder name: String?) {
        let target = name.map { libraryRoot.appendingPathComponent($0) } ?? libraryRoot
        var done: [(URL,URL)] = [], problems: [String] = []
        for url in urls where ProjectFolder.isProject(url) {
            if let reason = lockReason(url) { problems.append("\(RecordingInfo.title(url)): \(reason)"); continue }
            do { let new = try Library.move(url,to: target); if new != url { done.append((url,new)) } }
            catch { problems.append("\(RecordingInfo.title(url)): \(error.localizedDescription)") }
        }
        moved(done); refreshLibrary()
        if !done.isEmpty { status = "\(done.count == 1 ? "Aufnahme" : "\(done.count) Aufnahmen") verschoben nach „\(name ?? "Alle Aufnahmen")“" }
        if !problems.isEmpty { self.error = "Nicht verschoben:\n"+problems.joined(separator: "\n") }
    }
    /// Puts a recording in the Trash (restorable in Finder). An open take is closed first.
    func trash(_ url: URL) {
        if let reason = lockReason(url) { self.error = "Kann gerade nicht gelöscht werden: \(reason)."; return }
        let key = url.standardizedFileURL.path
        if directory?.standardizedFileURL.path == key { closeProject() }
        do {
            try Library.trash(url)
            recent.removeAll { $0.standardizedFileURL.path == key }
            UserDefaults.standard.set(recent.map(\.path),forKey: "recentProjects")
            refreshLibrary(); status = "In den Papierkorb gelegt · im Finder wiederherstellbar"
        } catch { self.error = error.localizedDescription }
    }
    func renameRecording(_ url: URL,to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if directory?.standardizedFileURL.path == url.standardizedFileURL.path { rename(clean); return }
        do { try Project.update(in: url) { $0.name = clean }; objectWillChange.send(); status = "Umbenannt in „\(clean)“" }
        catch { self.error = error.localizedDescription }
    }
    func removeFromRecent(_ url: URL) {
        recent.removeAll { $0 == url }
        UserDefaults.standard.set(recent.map(\.path),forKey: "recentProjects")
        refreshLibrary()
    }
    /// Keeps the recent list and the open take in step with moves on disk.
    func moved(_ pairs: [(URL,URL)]) {
        guard !pairs.isEmpty else { return }
        let map = Dictionary(pairs.map { ($0.0.standardizedFileURL.path,$0.1) },uniquingKeysWith: { $1 })
        recent = recent.map { map[$0.standardizedFileURL.path] ?? $0 }
        UserDefaults.standard.set(recent.map(\.path),forKey: "recentProjects")
        if let directory, let target = map[directory.standardizedFileURL.path] { relocateOpenProject(to: target) }
    }
}
