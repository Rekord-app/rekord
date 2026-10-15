import Foundation
import CoreGraphics
import CryptoKit

public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let center = Point(0.5, 0.5)
    public func clamped() -> Point { Point(min(1, max(0, x)), min(1, max(0, y))) }
    public func mixed(with b: Point, by t: Double) -> Point { Point(x + (b.x-x)*t, y + (b.y-y)*t) }
}
public struct PointerSample: Codable, Equatable, Sendable {
    public var time: Double
    public var position: Point
    public var clicked: Bool
    public var visible: Bool
    public init(time: Double, position: Point, clicked: Bool = false, visible: Bool = true) {
        self.time = time; self.position = position; self.clicked = clicked; self.visible = visible
    }
}
public struct Cut: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var duration: Double { max(0, end-start) }
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}
public struct ZoomSegment: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var scale: Double
    public var focus: Point
    public var followsCursor: Bool
    public init(start: Double, end: Double, scale: Double = 2.0, focus: Point = .center, followsCursor: Bool = true) {
        self.start = start; self.end = end; self.scale = scale; self.focus = focus; self.followsCursor = followsCursor
    }
}
public enum CanvasFormat: String, Codable, CaseIterable, Sendable {
    case landscape = "16:9", portrait = "9:16", square = "1:1", vertical = "4:5"
    /// Pixel size for an export quality given by its short side (1080 → 1920×1080, 1080×1920, 1080×1080, 1080×1350).
    public func dimensions(height: Int) -> (Int, Int) {
        let short = height / 2 * 2
        switch self {
        case .landscape: return (height*16/9 / 2 * 2, short)
        case .portrait: return (short, height*16/9 / 2 * 2)
        case .square: return (short, short)
        case .vertical: return (short, height*5/4 / 2 * 2)
        }
    }
    public var label: String {
        switch self {
        case .landscape: return "16:9 · Quer (YouTube)"
        case .portrait: return "9:16 · Hoch (Reels, TikTok)"
        case .square: return "1:1 · Quadrat"
        case .vertical: return "4:5 · Hoch (Feed)"
        }
    }
}
public enum RecordingMode: String, Codable, CaseIterable, Sendable { case studio, loom }
/// How click zooms are generated: zoom strength, how early before the click it starts, how long it holds after.
public struct AutoZoomSettings: Codable, Equatable, Sendable {
    public var scale: Double
    public var lead: Double
    public var hold: Double
    public init(scale: Double = 2,lead: Double = 0.4,hold: Double = 1.8) { self.scale = scale; self.lead = lead; self.hold = hold }
    public static let standard = AutoZoomSettings()
    public var valid: Bool { (1.25...4).contains(scale) && (0...1.5).contains(lead) && (0.5...5).contains(hold) }
}
/// Shape of the camera in the video. Rounded and square use continuous (superellipse) corners like macOS icons.
public enum CameraShape: String, Codable, CaseIterable, Sendable {
    case circle, rounded, square
    public var label: String { switch self { case .circle: return "Kreis"; case .rounded: return "Abgerundet"; case .square: return "Eckig" } }
    /// Path for the shape in `rect` (square rect expected).
    public func path(in rect: CGRect) -> CGPath {
        if self == .circle { return CGPath(ellipseIn: rect,transform: nil) }
        let n = self == .rounded ? 4.6 : 14.0
        let path = CGMutablePath(), a = rect.width/2, b = rect.height/2
        for i in 0..<160 {
            let t = Double(i)/160*2*Double.pi, c = cos(t), s = sin(t)
            let x = rect.midX+a*(c < 0 ? -1 : 1)*pow(abs(c),2/n), y = rect.midY+b*(s < 0 ? -1 : 1)*pow(abs(s),2/n)
            if i == 0 { path.move(to: CGPoint(x: x,y: y)) } else { path.addLine(to: CGPoint(x: x,y: y)) }
        }
        path.closeSubpath()
        return path
    }
}
/// Camera proportions in the video.
public enum CameraAspect: String, Codable, CaseIterable, Sendable {
    case square = "1:1", landscape = "4:3", wide = "16:9", portrait = "3:4"
    public var ratio: Double { switch self { case .square: return 1; case .landscape: return 4.0/3; case .wide: return 16.0/9; case .portrait: return 3.0/4 } }
    public var label: String { switch self { case .square: return "Quadrat"; case .landscape: return "Quer 4:3"; case .wide: return "Breit 16:9"; case .portrait: return "Hoch 3:4" } }
}
/// One-click camera looks (shape, proportions, size, frame).
public enum CameraPreset: String, CaseIterable, Sendable {
    case bubble, tile, wide, portrait, polaroid
    public var label: String { switch self { case .bubble: return "Bubble"; case .tile: return "Kachel"; case .wide: return "Breit"; case .portrait: return "Hochkant"; case .polaroid: return "Polaroid" } }
    public func apply(to style: inout Style) {
        switch self {
        case .bubble: style.cameraShape = .circle; style.cameraAspect = .square; style.cameraSize = 0.22; style.cameraBorder = false
        case .tile: style.cameraShape = .rounded; style.cameraAspect = .square; style.cameraSize = 0.26; style.cameraBorder = false
        case .wide: style.cameraShape = .rounded; style.cameraAspect = .wide; style.cameraSize = 0.27; style.cameraBorder = false
        case .portrait: style.cameraShape = .rounded; style.cameraAspect = .portrait; style.cameraSize = 0.3; style.cameraBorder = false
        case .polaroid: style.cameraShape = .square; style.cameraAspect = .square; style.cameraSize = 0.26; style.cameraBorder = true
        }
    }
}
/// How the camera is placed during a stretch of the video (outside segments it floats as the overlay).
public enum CameraLayout: String, Codable, CaseIterable, Sendable {
    case fullscreen, split, hidden
    public var label: String { switch self { case .fullscreen: return "Vollbild"; case .split: return "Geteilt"; case .hidden: return "Ausgeblendet" } }
    public var icon: String { switch self { case .fullscreen: return "person.crop.rectangle"; case .split: return "rectangle.split.2x1"; case .hidden: return "eye.slash" } }
}
public struct CameraLayoutSegment: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var layout: CameraLayout
    public init(start: Double,end: Double,layout: CameraLayout) { self.start = start; self.end = end; self.layout = layout }
}
public enum ClickEffect: String, Codable, CaseIterable, Sendable {
    case ring, pulse, none
    public var label: String { switch self { case .ring: return "Ring"; case .pulse: return "Puls"; case .none: return "Aus" } }
}
/// Part of the recorded source shown in the video, normalized to the source (origin top-left).
public struct CropRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double,y: Double,width: Double,height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width >= 0.1 && height >= 0.1 && x+width <= 1.0001 && y+height <= 1.0001 }
    public enum Preset: String, CaseIterable, Sendable { case original, widescreenWithoutMenuBar, widescreenCentered }
    /// Share of a Mac display taken by the menu bar (37 pt of 956 pt on a 13" MacBook Air with notch).
    public static let menuBarShare = 37.0/956.0
    /// Whole-display recordings a bit taller than 16:9 (MacBooks at 16:10 or 1.54:1) are cropped to 16:9
    /// automatically, so YouTube and Loom show them full-bleed instead of with bars. Wider or much taller
    /// sources (ultrawide, portrait displays) keep their shape.
    public static func automaticWidescreen(sourceWidth: Int,sourceHeight: Int,menuBar: Double = menuBarShare) -> CropRect? {
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let aspect = Double(sourceWidth)/Double(sourceHeight)
        guard aspect >= 1.4, aspect < 16.0/9.0-0.01 else { return nil }
        return preset(.widescreenWithoutMenuBar,sourceWidth: sourceWidth,sourceHeight: sourceHeight,menuBar: menuBar)
    }
    /// The preset a crop corresponds to (menu bar height may differ per display).
    public func matchingPreset(sourceWidth: Int,sourceHeight: Int) -> Preset {
        abs(y-(1-height)/2) < 0.002 && abs(x-(1-width)/2) < 0.002 ? .widescreenCentered : .widescreenWithoutMenuBar
    }
    /// Crop for a preset on a source of the given pixel size; nil means the full source.
    public static func preset(_ preset: Preset,sourceWidth: Int,sourceHeight: Int,menuBar: Double = menuBarShare) -> CropRect? {
        let w = Double(sourceWidth), h = Double(sourceHeight), target = 16.0/9.0
        guard preset != .original, w > 0, h > 0, abs(w/h-target) > 0.01 else { return nil }
        if w/h > target {
            let share = h*target/w
            return CropRect(x: (1-share)/2,y: 0,width: share,height: 1)
        }
        let share = w/target/h, slack = 1-share
        // Without menu bar: drop the menu bar at the top, take the remaining slack from the bottom (Dock).
        let top = preset == .widescreenWithoutMenuBar ? min(slack,max(0,menuBar)) : slack/2
        return CropRect(x: 0,y: top,width: 1,height: share)
    }
}
public struct Style: Codable, Equatable, Sendable {
    public var format: CanvasFormat = .landscape
    public var background: Background = .nightStudio
    public var backdrop: BackdropSettings?
    /// Motion blur strength 0…1 (1 = 360° shutter at 60 fps). Optional so older projects decode; nil uses the default.
    public var motionBlur: Double?
    public static let defaultMotionBlur = 0.5
    /// Source crop; nil shows the whole recording.
    public var crop: CropRect?
    /// How much the cursor leans into fast horizontal movement (0 = never). nil uses the default.
    public var cursorTilt: Double?
    public static let defaultCursorTilt = 0.5
    /// Visual feedback on clicks; nil uses the ring.
    public var clickEffect: ClickEffect?
    /// Camera shape; nil uses a circle for Loom and continuous rounded corners for Studio.
    public var cameraShape: CameraShape?
    /// Thin white outline around the camera (off by default).
    public var cameraBorder: Bool?
    /// Camera size while fully zoomed in, relative to its normal size (0.7 = shrinks to 70 %, 1.3 = grows).
    public var cameraZoomScale: Double?
    public static let defaultCameraZoomScale = 0.7
    /// Camera proportions; nil is square.
    public var cameraAspect: CameraAspect?
    public var padding: Double = 0.065
    public var cornerRadius: Double = 0.025
    public var shadow: Double = 0.75
    public var cursorSize: Double = 1
    public var smoothing: Double = 0.08
    public var showCursor = true
    public var showCamera = true
    public var cameraSize: Double = 0.23
    public var cameraPosition = Point(0.84, 0.81)
    public var mirrorCamera = true
    public init() {}
}
public struct Project: Codable, Sendable {
    public var version = 1
    public var mode: RecordingMode?
    public var hasMicrophone: Bool?
    public var microphoneOffset: Double?
    public var recordingMode: RecordingMode { mode ?? .studio }
    public var defaultExportFPS: Int { recordingMode == .studio ? fps : 30 }
    // Leave headroom when narration and system audio are mixed together.
    public func audioGain(isMicrophone: Bool) -> Float { hasMicrophone == true ? (isMicrophone ? 0.75 : 0.25) : 1 }
    public var name: String
    public var duration: Double
    public var width: Int
    public var height: Int
    public var fps: Int
    public var cameraOffset: Double = 0
    public var hasCamera = false
    public var pointer: [PointerSample] = []
    public var cuts: [Cut]
    public var zooms: [ZoomSegment] = []
    /// Settings last used to generate click zooms; nil means the standard settings.
    public var autoZoom: AutoZoomSettings?
    /// Stretches where the camera is full screen, split with the screen, or hidden (source time).
    public var cameraLayouts: [CameraLayoutSegment]?
    public var style = Style()
    public init(name: String, duration: Double, width: Int, height: Int, fps: Int = 60) {
        self.name = name; self.duration = duration; self.width = width; self.height = height; self.fps = fps
        cuts = duration > 0 ? [Cut(start: 0, end: duration)] : []
    }
    public func fingerprint() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format:"%02x",$0) }.joined()
    }
    public var editedDuration: Double { cuts.reduce(0) { $0 + $1.duration } }
    public func sourceTime(at editedTime: Double) -> Double {
        var remaining = max(0, editedTime)
        for cut in cuts {
            if remaining < cut.duration { return cut.start + remaining }
            remaining -= cut.duration
        }
        return cuts.last?.end ?? 0
    }
    public mutating func split(at time: Double) {
        guard let i = cuts.firstIndex(where: { time > $0.start + 0.05 && time < $0.end - 0.05 }) else { return }
        let cut = cuts[i]
        cuts.replaceSubrange(i...i, with: [Cut(start: cut.start, end: time), Cut(start: time, end: cut.end)])
    }
    public func validate() throws {
        guard version == 1, duration.isFinite, duration > 0, width > 0, height > 0, [30,60].contains(fps), !cuts.isEmpty else { throw ProjectError.invalid }
        guard style.backdrop?.valid ?? true, (0...1).contains(style.motionBlur ?? 0), (0...1).contains(style.cursorTilt ?? 0), (0.4...1.6).contains(style.cameraZoomScale ?? 1), style.crop?.valid ?? true, autoZoom?.valid ?? true,
              (cameraLayouts ?? []).allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.001 }) else { throw ProjectError.invalid }
        var previous = 0.0
        for cut in cuts {
            guard cut.start.isFinite, cut.end.isFinite, cut.start >= previous, cut.duration >= 0.03, cut.end <= duration + 0.001 else { throw ProjectError.invalid }
            previous = cut.end
        }
        guard pointer.allSatisfy({ $0.time.isFinite && $0.position.x.isFinite && $0.position.y.isFinite }),
              zip(pointer, pointer.dropFirst()).allSatisfy({ $0.time <= $1.time }),
              zooms.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.001 && (1...4).contains($0.scale) && (0...1).contains($0.focus.x) && (0...1).contains($0.focus.y) }),
              (0...0.25).contains(style.padding), (0...0.15).contains(style.cornerRadius), (0...1).contains(style.shadow),
              (0...0.5).contains(style.smoothing), (0.5...3).contains(style.cursorSize), (0.1...0.5).contains(style.cameraSize),
              (0...1).contains(style.cameraPosition.x), (0...1).contains(style.cameraPosition.y), cameraOffset.isFinite, (microphoneOffset ?? 0).isFinite else { throw ProjectError.invalid }
    }
    /// Retained ranges of a recording: everything except the paused intervals (fragments under 30 ms dropped).
    public static func retainedCuts(duration: Double,pauses: [(start: Double,end: Double)]) -> [Cut] {
        var cuts: [Cut] = [], cursor = 0.0
        for pause in pauses.sorted(by: { $0.start < $1.start }) {
            let start = max(cursor,min(duration,pause.start)), end = max(start,min(duration,pause.end))
            if start-cursor >= 0.03 { cuts.append(Cut(start: cursor,end: start)) }
            cursor = max(cursor,end)
        }
        if duration-cursor >= 0.03 { cuts.append(Cut(start: cursor,end: duration)) }
        return cuts.isEmpty ? [Cut(start: 0,end: duration)] : cuts
    }
    /// The project as the renderer sees it after cropping: source size, pointer and zoom focus in crop space.
    public func applyingCrop() -> Project {
        guard let crop = style.crop, crop != CropRect(x: 0,y: 0,width: 1,height: 1) else { return self }
        var view = self
        view.width = max(2,Int((Double(width)*crop.width).rounded())); view.height = max(2,Int((Double(height)*crop.height).rounded()))
        func map(_ p: Point) -> Point { Point((p.x-crop.x)/crop.width,(p.y-crop.y)/crop.height) }
        view.pointer = pointer.map { sample in
            var sample = sample; let p = map(sample.position)
            sample.visible = sample.visible && (0...1).contains(p.x) && (0...1).contains(p.y)
            sample.position = p.clamped(); return sample
        }
        view.zooms = zooms.map { var zoom = $0; zoom.focus = map(zoom.focus).clamped(); return zoom }
        view.style.crop = nil
        return view
    }
    public func save(to directory: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("project.json"), options: .atomic)
    }
    /// Saves only if project.json is still the version the caller started from (`expecting`), under an exclusive
    /// lock shared by the app and every MCP server. Returns the new version. Concurrent writers therefore never
    /// replace each other's newer state silently: they get `ProjectError.conflict` and re-apply their change.
    @discardableResult public func save(to directory: URL,expecting: ProjectVersion?) throws -> ProjectVersion {
        try validate()
        return try ProjectVersion.locked(directory) {
            if let expecting, ProjectVersion.current(directory) != expecting { throw ProjectError.conflict }
            try save(to: directory)
            return ProjectVersion.current(directory) ?? ProjectVersion(modified: Date(),size: 0)
        }
    }
    /// Read-modify-write against the newest state on disk (retries if another writer slips in).
    @discardableResult public static func update(in directory: URL,_ mutation: (inout Project) throws -> Void) throws -> (Project,ProjectVersion) {
        for _ in 0..<5 {
            let version = ProjectVersion.current(directory)
            var project = try Project.load(from: directory)
            try mutation(&project)
            do { return (project,try project.save(to: directory,expecting: version)) } catch ProjectError.conflict { continue }
        }
        throw ProjectError.conflict
    }
    public static func load(from directory: URL) throws -> Project {
        let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: directory.appendingPathComponent("project.json")))
        try project.validate()
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("screen.mov").path) else { throw ProjectError.missingMedia }
        return project
    }
}
public enum ProjectError: LocalizedError {
    case invalid, missingMedia, missingBackground, conflict
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .conflict: return "Die Aufnahme wurde gleichzeitig an anderer Stelle geändert. Bitte erneut versuchen."
        case .invalid: return "Ungültige Projektdaten oder Zeitbereiche."
        case .missingMedia: return "Die Quelldatei screen.mov fehlt im Projektordner."
        case .missingBackground: return "Das Hintergrundbild fehlt oder kann nicht gelesen werden. Bitte im Look-Bereich erneut auswählen."
        }
    }
}

/// Recording projects are folders: `.rekord` (before the rename `.focusrec`, still opened everywhere).
public enum ProjectFolder {
    public static let fileExtension = "rekord"
    public static let extensions: Set<String> = ["rekord","focusrec"]
    public static func isProject(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
}
/// Where recordings are stored: `~/Movies/Rekord`. Installs from before the rename used `~/Movies/Focus Recorder`;
/// the app moves that folder once (`migrateLegacy`), until then it is used as is.
public enum RecordingsFolder {
    static var movies: URL { FileManager.default.urls(for: .moviesDirectory,in: .userDomainMask)[0] }
    public static var legacy: URL { movies.appendingPathComponent("Focus Recorder") }
    public static var current: URL { movies.appendingPathComponent("Rekord") }
    public static var url: URL {
        if let root = ProcessInfo.processInfo.environment["REKORD_RECORDINGS_ROOT"] { return URL(fileURLWithPath: root) }
        return !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: legacy.path) ? legacy : current
    }
    /// Moves `~/Movies/Focus Recorder` to `~/Movies/Rekord` when only the old folder exists. Returns true after a move.
    @discardableResult public static func migrateLegacy() -> Bool {
        guard ProcessInfo.processInfo.environment["REKORD_RECORDINGS_ROOT"] == nil else { return false }
        let files = FileManager.default
        guard !files.fileExists(atPath: current.path), files.fileExists(atPath: legacy.path) else { return false }
        return (try? files.moveItem(at: legacy,to: current)) != nil
    }
    /// Rewrites a path inside the old folder to the new one.
    public static func migratedPath(_ path: String) -> String {
        path.hasPrefix(legacy.path+"/") ? current.path+path.dropFirst(legacy.path.count) : path
    }
}
/// Application Support folder for status.json (shared with the MCP server).
public enum SupportFolder {
    public static var url: URL {
        if let root = ProcessInfo.processInfo.environment["REKORD_SUPPORT_ROOT"] { return URL(fileURLWithPath: root) }   // tests
        return FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("Rekord")
    }
}

/// Identity of a saved project.json (modification time + size), used to detect writes by other processes.
public struct ProjectVersion: Equatable, Sendable {
    public let modified: Date
    public let size: Int
    public static func current(_ directory: URL) -> ProjectVersion? {
        guard let values = try? directory.appendingPathComponent("project.json").resourceValues(forKeys: [.contentModificationDateKey,.fileSizeKey]),
              let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
        return ProjectVersion(modified: modified,size: size)
    }
    /// Runs `body` while holding an exclusive advisory lock on the project (app and MCP servers use the same lock file).
    static func locked<T>(_ directory: URL,_ body: () throws -> T) throws -> T {
        let path = directory.appendingPathComponent(".project.lock").path
        let fd = open(path,O_CREAT|O_RDWR|O_CLOEXEC,0o644)
        guard fd >= 0 else { return try body() }
        defer { flock(fd,LOCK_UN); close(fd) }
        flock(fd,LOCK_EX)
        return try body()
    }
}
