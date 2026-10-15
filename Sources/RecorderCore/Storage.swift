import Foundation

/// Disk usage of Rekord and the optional automatic cleanup:
/// - shared Loom takes that were not touched for N days go to the Trash (the share link stays on the server,
///   and the Trash keeps the take recoverable),
/// - Studio takes not touched for N days move to an archive folder (e.g. an external drive) and stay openable there.
/// Meetings and guides are never touched; neither is an open, recording or interrupted take.
public enum Storage {
    public struct Item: Equatable, Sendable {
        public let url: URL
        public let mode: RecordingMode
        /// Last change to project.json (editing a take resets its clock).
        public let lastUsed: Date
        public let bytes: Int64
        /// Has an active share link (share.json present).
        public let shared: Bool
    }
    public struct Usage: Equatable, Sendable {
        public var studio: Int64 = 0, loom: Int64 = 0, meetings: Int64 = 0, guides: Int64 = 0
        public var inventoryImages: Int64 = 0, inventorySamples: Int64 = 0
        public var freeOnDisk: Int64 = 0
        public var recordings: Int64 { studio+loom }
        public var total: Int64 { studio+loom+meetings+guides+inventoryImages+inventorySamples }
    }
    public struct Policy: Codable, Equatable, Sendable {
        /// Days after which shared Loom takes go to the Trash; nil = never.
        public var loomTrashDays: Int? = 30
        /// Days after which Studio takes move to `archiveFolder`; nil = never.
        public var studioArchiveDays: Int?
        public var archiveFolder: String?
        public init(loomTrashDays: Int? = 30,studioArchiveDays: Int? = nil,archiveFolder: String? = nil) {
            self.loomTrashDays = loomTrashDays; self.studioArchiveDays = studioArchiveDays; self.archiveFolder = archiveFolder
        }
    }
    public enum Action: Equatable, Sendable {
        case trash(Item)
        case archive(Item,to: URL)
        public var item: Item { switch self { case .trash(let item),.archive(let item,_): return item } }
    }

    /// Recording projects in `folder` and its user folders (meetings, guides and inventory are skipped).
    public static func scan(_ folder: URL) -> [Item] {
        let files = FileManager.default
        return Library.projects(in: folder).compactMap { dir in
            let json = dir.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: json), let project = try? JSONDecoder().decode(Project.self,from: data),
                  let modified = (try? json.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return Item(url: dir,mode: project.recordingMode,lastUsed: modified,bytes: size(of: dir),
                        shared: files.fileExists(atPath: dir.appendingPathComponent("share.json").path))
        }
    }
    public static func usage(_ folder: URL) -> Usage {
        var usage = Usage()
        for item in scan(folder) { if item.mode == .loom { usage.loom += item.bytes } else { usage.studio += item.bytes } }
        usage.meetings = size(of: folder.appendingPathComponent("Meetings"))
        usage.guides = size(of: folder.appendingPathComponent("Anleitungen"))
        let inventory = InventoryRetention.usage(root: folder.appendingPathComponent("Inventur"))
        usage.inventoryImages = inventory.images; usage.inventorySamples = inventory.samples
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        usage.freeOnDisk = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return usage
    }
    /// What the policy would do now. `protected` holds folders that must not move (open or recording take).
    public static func plan(_ items: [Item],policy: Policy,now: Date = Date(),protected: Set<String> = []) -> [Action] {
        let files = FileManager.default
        var archive: URL?
        if let path = policy.archiveFolder {
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: path,isDirectory: &isDirectory), isDirectory.boolValue, files.isWritableFile(atPath: path) { archive = URL(fileURLWithPath: path) }
        }
        return items.compactMap { item in
            let key = item.url.standardizedFileURL.path
            guard !protected.contains(key),
                  !files.fileExists(atPath: item.url.appendingPathComponent(RecoveryJournal.journalName).path) else { return nil }
            let idleDays = now.timeIntervalSince(item.lastUsed)/86400
            if item.mode == .loom, item.shared, let days = policy.loomTrashDays, idleDays >= Double(days) { return .trash(item) }
            if item.mode == .studio, let days = policy.studioArchiveDays, let archive, idleDays >= Double(days),
               !key.hasPrefix(archive.standardizedFileURL.path+"/") { return .archive(item,to: archive) }
            return nil
        }
    }
    /// Carries out the actions. Returns the old→new location of archived takes (nil for trashed ones) and errors.
    public static func apply(_ actions: [Action]) -> (moved: [(from: URL,to: URL?)],failed: [(URL,String)]) {
        let files = FileManager.default
        var moved: [(from: URL,to: URL?)] = [], failed: [(URL,String)] = []
        for action in actions {
            do {
                switch action {
                case .trash(let item):
                    try files.trashItem(at: item.url,resultingItemURL: nil)
                    moved.append((item.url,nil))
                case .archive(let item,let folder):
                    var target = folder.appendingPathComponent(item.url.lastPathComponent), n = 2
                    while files.fileExists(atPath: target.path) {
                        target = folder.appendingPathComponent("\(item.url.deletingPathExtension().lastPathComponent) \(n).\(item.url.pathExtension)"); n += 1
                    }
                    try files.moveItem(at: item.url,to: target)
                    moved.append((item.url,target))
                }
            } catch { failed.append((action.item.url,error.localizedDescription)) }
        }
        return (moved,failed)
    }
    public static func size(of url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url,includingPropertiesForKeys: [.totalFileAllocatedSizeKey,.isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey,.isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
    public static func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes,countStyle: .file) }
}
