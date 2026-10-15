import Foundation

/// The recordings library: `.rekord` projects directly in the recordings folder plus one level of user folders
/// („Kunde A“, „YouTube“). Folders are plain Finder folders, so Finder and the app always agree.
/// Meetings, guides, inventory and hidden folders are not user folders and are never touched here.
public enum Library {
    /// Subfolders that belong to other modes.
    public static let reserved: Set<String> = ["meetings","anleitungen","inventur"]

    /// User folders in `root`, sorted like Finder.
    public static func folders(in root: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root,includingPropertiesForKeys: [.isDirectoryKey],options: [.skipsHiddenFiles])) ?? []
        return entries.filter(isUserFolder).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    /// Every project in `root` and its user folders.
    public static func projects(in root: URL) -> [URL] {
        ([root]+folders(in: root)).flatMap { projects(directlyIn: $0) }
    }
    public static func projects(directlyIn folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder,includingPropertiesForKeys: nil,options: [.skipsHiddenFiles])) ?? [])
            .filter { ProjectFolder.isProject($0) && FileManager.default.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
    }
    /// Name of the user folder a project sits in, nil when it sits directly in `root` (or elsewhere).
    public static func folder(of project: URL,root: URL) -> String? {
        let parent = project.deletingLastPathComponent().standardizedFileURL
        guard parent.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else { return nil }
        return parent.lastPathComponent
    }
    static func isUserFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), !ProjectFolder.isProject(url), !reserved.contains(name.lowercased()) else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Creates a user folder; the name must be new, visible and not belong to another mode.
    @discardableResult public static func createFolder(_ name: String,in root: URL) throws -> URL {
        let target = root.appendingPathComponent(try validName(name,in: root))
        try FileManager.default.createDirectory(at: target,withIntermediateDirectories: true)
        return target
    }
    @discardableResult public static func renameFolder(_ folder: URL,to name: String) throws -> URL {
        let root = folder.deletingLastPathComponent()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean == folder.lastPathComponent { return folder }
        // A change of case only („kunden“ → „Kunden“) is the same folder on APFS; the check would refuse it.
        let target = root.appendingPathComponent(clean.lowercased() == folder.lastPathComponent.lowercased() ? clean : try validName(clean,in: root))
        try FileManager.default.moveItem(at: folder,to: target)
        return target
    }
    /// Dissolves a folder: its recordings move back to `root`, the empty folder goes to the Trash.
    /// Returns the old→new location of every moved recording.
    @discardableResult public static func dissolveFolder(_ folder: URL,into root: URL) throws -> [(from: URL,to: URL)] {
        var moved: [(from: URL,to: URL)] = []
        for project in projects(directlyIn: folder) { moved.append((project,try move(project,to: root))) }
        let rest = (try? FileManager.default.contentsOfDirectory(at: folder,includingPropertiesForKeys: nil)) ?? []
        if rest.allSatisfy({ $0.lastPathComponent == ".DS_Store" }) { try FileManager.default.trashItem(at: folder,resultingItemURL: nil) }
        return moved
    }
    /// Moves a project into `folder` (a user folder or `root`); a name clash gets a number. Returns the new location.
    @discardableResult public static func move(_ project: URL,to folder: URL) throws -> URL {
        let files = FileManager.default
        if project.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path { return project }
        guard files.fileExists(atPath: project.appendingPathComponent("project.json").path) else { throw ProjectError.message("Aufnahme nicht gefunden: \(project.lastPathComponent)") }
        guard !files.fileExists(atPath: project.appendingPathComponent(RecoveryJournal.journalName).path) else {
            throw ProjectError.message("Diese Aufnahme wird gerade aufgenommen oder gerettet und kann noch nicht verschoben werden.")
        }
        let base = project.deletingPathExtension().lastPathComponent, ext = project.pathExtension
        var target = folder.appendingPathComponent(project.lastPathComponent), n = 2
        while files.fileExists(atPath: target.path) { target = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 }
        try files.moveItem(at: project,to: target)
        return target
    }
    /// Puts a project in the Trash (recoverable in Finder).
    public static func trash(_ project: URL) throws {
        guard ProjectFolder.isProject(project) else { throw ProjectError.message("Nur Rekord-Aufnahmen können hier gelöscht werden.") }
        guard !FileManager.default.fileExists(atPath: project.appendingPathComponent(RecoveryJournal.journalName).path) else {
            throw ProjectError.message("Diese Aufnahme wird gerade aufgenommen oder gerettet und kann noch nicht gelöscht werden.")
        }
        try FileManager.default.trashItem(at: project,resultingItemURL: nil)
    }
    /// Temporary locations (test runs, snapshots) never belong in the recent list.
    public static func isTemporary(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return ["/tmp/","/private/tmp/","/var/folders/","/private/var/folders/",temp.hasSuffix("/") ? temp : temp+"/"].contains { path.hasPrefix($0) }
    }
    static func validName(_ name: String,in root: URL) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ProjectError.message("Bitte einen Ordnernamen eingeben.") }
        guard !clean.contains("/"), !clean.contains(":"), !clean.hasPrefix("."), clean.count <= 80 else {
            throw ProjectError.message("Ordnernamen dürfen nicht mit einem Punkt beginnen und weder „/“ noch „:“ enthalten.")
        }
        guard !reserved.contains(clean.lowercased()), !ProjectFolder.isProject(URL(fileURLWithPath: clean)) else {
            throw ProjectError.message("„\(clean)“ ist für Rekord reserviert. Bitte einen anderen Namen wählen.")
        }
        let taken = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).map { $0.lowercased() }
        guard !taken.contains(clean.lowercased()) else { throw ProjectError.message("Ein Ordner „\(clean)“ existiert schon.") }
        return clean
    }
}
