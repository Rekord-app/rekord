import Foundation

/// Guards export destinations: an export must never replace recording data — the project's own files
/// (originals, project.json, assets, receipts) or anything inside another recording — however the path is spelled
/// (relative segments, symlinked folders, a symlink or hard link to an original).
public enum ExportTarget {
    /// Derived files inside a project that an export may (re)write.
    public static let projectArtifacts: Set<String> = ["share.mp4"]

    public static func validate(_ destination: URL,projectDirectory: URL) throws {
        let files = FileManager.default
        let target = canonical(destination), project = canonical(projectDirectory)
        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: target.path,isDirectory: &isDirectory), isDirectory.boolValue {
            throw ExportError.message("Exportziel ist ein Ordner: \(destination.path)")
        }
        if target.path == project.path || target.path.hasPrefix(project.path+"/") {
            let relative = String(target.path.dropFirst(project.path.count+1))
            guard projectArtifacts.contains(relative) else { throw protected(destination) }
        }
        // Inside any other recording (by folder extension).
        var parent = target.deletingLastPathComponent()
        while parent.path != "/" && !parent.path.isEmpty {
            if parent.path != project.path, ProjectFolder.isProject(parent) { throw protected(destination) }
            parent = parent.deletingLastPathComponent()
        }
        // Same file under another name (hard link, or a symlink resolved above) as anything in the project.
        if files.fileExists(atPath: target.path), let id = identifier(target) {
            let contents = files.enumerator(at: project,includingPropertiesForKeys: [.fileResourceIdentifierKey],options: [.skipsPackageDescendants])
            while let file = contents?.nextObject() as? URL {
                if projectArtifacts.contains(file.lastPathComponent) && file.deletingLastPathComponent().path == project.path { continue }
                if let other = identifier(file), other.isEqual(id) { throw protected(destination) }
            }
        }
    }
    /// Absolute path with `..` removed and symlinks resolved, also when the file itself does not exist yet.
    public static func canonical(_ url: URL) -> URL {
        let standard = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: standard.path) { return standard.resolvingSymlinksInPath() }
        return standard.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(standard.lastPathComponent)
    }
    private static func identifier(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
    }
    private static func protected(_ url: URL) -> ExportError {
        ExportError.message("Exportziel gehört zur Aufnahme und wird nicht überschrieben: \(url.path). Bitte einen Pfad außerhalb des .rekord-Ordners wählen.")
    }
}
