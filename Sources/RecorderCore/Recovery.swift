import Foundation
@preconcurrency import AVFoundation

/// Crash and failure safety for recordings. While recording, a small journal next to the media (`recovery.json`
/// plus append-only pointer samples in `recovery-pointer.ndjson`) describes the take; the screen and camera
/// movies are written as fragmented QuickTime files, so they stay readable up to the last fragment even if the
/// app dies. A normal Stop removes the journal after project.json is written. On the next launch any take that
/// still has a journal but no project.json is turned into a normal, openable project.
public final class RecoveryJournal {
    public static let journalName = "recovery.json"
    public static let pointerName = "recovery-pointer.ndjson"
    private let directory: URL
    private var template: Project
    private var writtenSamples = 0
    private let encoder = JSONEncoder()

    public init(directory: URL,template: Project) {
        self.directory = directory; self.template = template
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.pointerName))
    }
    /// Saves the take's current state. Pointer samples are appended, so a long take stays cheap to checkpoint.
    public func checkpoint(width: Int,height: Int,fps: Int,duration: Double,samples: ArraySlice<PointerSample>,
                           cuts: [Cut]?,hasCamera: Bool,hasMicrophone: Bool,cameraOffset: Double?,microphoneOffset: Double?) {
        var snapshot = template
        snapshot.width = width; snapshot.height = height; snapshot.fps = fps; snapshot.duration = duration
        if let cuts { snapshot.cuts = cuts }
        snapshot.hasCamera = hasCamera; snapshot.hasMicrophone = hasMicrophone
        if let cameraOffset { snapshot.cameraOffset = cameraOffset }
        if let microphoneOffset { snapshot.microphoneOffset = microphoneOffset }
        snapshot.pointer = []
        if let data = try? encoder.encode(snapshot) { try? data.write(to: directory.appendingPathComponent(Self.journalName),options: .atomic) }
        let fresh = samples.dropFirst(min(writtenSamples,samples.count))
        guard !fresh.isEmpty else { return }
        var lines = Data()
        for sample in fresh { if let line = try? encoder.encode(sample) { lines.append(line); lines.append(0x0A) } }
        let url = directory.appendingPathComponent(Self.pointerName)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path,contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: lines); try? handle.close() }
        writtenSamples = samples.count
    }
    /// Removes the journal once the take is saved as a project.
    public static func finish(directory: URL) {
        for name in [journalName,pointerName] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    }
    /// Turns interrupted takes in `folder` into openable projects. Takes whose journal changed within
    /// `minimumAge` seconds are skipped (they may still be recording in another instance). Returns repaired folders.
    public static func repairIncomplete(in folder: URL,minimumAge: TimeInterval = 30) async -> [URL] {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(at: folder,includingPropertiesForKeys: nil) else { return [] }
        var repaired: [URL] = []
        for dir in entries where ProjectFolder.isProject(dir) {
            let journal = dir.appendingPathComponent(journalName)
            guard !files.fileExists(atPath: dir.appendingPathComponent("project.json").path), files.fileExists(atPath: journal.path),
                  let modified = (try? journal.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  Date().timeIntervalSince(modified) >= minimumAge else { continue }
            if (try? await repair(dir)) != nil { repaired.append(dir) }
        }
        return repaired
    }
    /// Builds project.json for one interrupted take from its journal and the readable part of its media.
    public static func repair(_ dir: URL) async throws -> Project {
        guard var project = try? JSONDecoder().decode(Project.self,from: Data(contentsOf: dir.appendingPathComponent(journalName))) else {
            throw ProjectError.message("Kein lesbares Aufnahme-Journal in \(dir.lastPathComponent).")
        }
        guard let duration = await playableDuration(dir.appendingPathComponent("screen.mov"),media: .video), duration > 0.1 else {
            throw ProjectError.message("Die Bildschirmspur von \(dir.lastPathComponent) ist nicht lesbar.")
        }
        project.duration = duration
        let lines = (try? String(contentsOf: dir.appendingPathComponent(pointerName),encoding: .utf8)) ?? ""
        project.pointer = lines.split(separator: "\n").compactMap { try? JSONDecoder().decode(PointerSample.self,from: Data($0.utf8)) }
            .filter { $0.time <= duration }.sorted { $0.time < $1.time }
        // Cuts from pauses: keep what lies inside the readable part.
        project.cuts = project.cuts.compactMap { cut in cut.start < duration ? Cut(start: cut.start,end: min(cut.end,duration)) : nil }.filter { $0.end-$0.start > 0.05 }
        if project.cuts.isEmpty { project.cuts = [Cut(start: 0,end: duration)] }
        if project.hasCamera, await playableDuration(dir.appendingPathComponent("camera.mov"),media: .video) == nil { project.hasCamera = false }
        if project.hasMicrophone == true, await playableDuration(dir.appendingPathComponent("microphone.m4a"),media: .audio) == nil { project.hasMicrophone = false }
        project.zooms = Motion.automaticZooms(pointer: project.pointer,duration: duration,settings: project.autoZoom ?? .standard)
        project.cameraLayouts = project.cameraLayouts?.filter { $0.end <= duration }
        if !project.name.hasSuffix("(gerettet)") { project.name += " (gerettet)" }
        try project.save(to: dir)
        finish(directory: dir)
        return project
    }
    static func playableDuration(_ url: URL,media: AVMediaType) async -> Double? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: media), let track = tracks.first,
              let range = try? await track.load(.timeRange), range.duration.isNumeric else { return nil }
        let seconds = range.duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
