import AppKit
@preconcurrency import AVFoundation
import RecorderCore

/// `--export-queue-check <dir> --project <recording.rekord>`: background exports keep the editor usable, render
/// the snapshot they were queued with, run in order, and can be cancelled while waiting.
@MainActor enum ExportQueueDiagnostics {
    static func run(arguments: [String]) async {
        guard let i = arguments.firstIndex(of: "--export-queue-check"),arguments.count > i+1,
              let p = arguments.firstIndex(of: "--project"),arguments.count > p+1 else { return }
        let root = URL(fileURLWithPath: arguments[i+1])
        var lines: [String] = []
        func log(_ value: String) { lines.append(value); try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("export-queue-report.txt"),atomically: true,encoding: .utf8) }
        let recent = UserDefaults.standard.object(forKey: "recentProjects")
        defer { UserDefaults.standard.set(recent,forKey: "recentProjects") }
        do {
            try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            let copy = root.appendingPathComponent("project.rekord")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[p+1]),to: copy)
            let store = EditorStore(); store.open(copy)
            guard var original = store.project else { throw RecorderError.message("Project did not open") }
            original.style.backdrop = BackdropSettings(kind: .solid); original.style.backdrop?.start = RGB(1,0,0); original.style.padding = 0.1
            store.edit { $0 = original }
            let queue = store.exports
            let first = root.appendingPathComponent("1-red.mp4"), second = root.appendingPathComponent("2-cancelled.mp4"), third = root.appendingPathComponent("3-green.mp4")
            queue.enqueue(project: store.project!,directory: copy,destination: first,height: 1080,fps: 30)
            queue.enqueue(project: store.project!,directory: copy,destination: second,height: 1080,fps: 30)
            queue.cancel(queue.jobs[1].id)
            // Edit while the first export renders: the editor stays usable and the running job keeps its snapshot.
            try await Task.sleep(nanoseconds: 200_000_000)
            guard queue.jobs[0].state == .running, !store.busy else { throw RecorderError.message("Export blocked the editor") }
            store.edit { $0.style.backdrop?.start = RGB(0,1,0) }
            guard store.project?.style.backdrop?.start == RGB(0,1,0) else { throw RecorderError.message("Edit during export was rejected") }
            queue.enqueue(project: store.project!,directory: copy,destination: third,height: 1080,fps: 30)
            log("PASS editor stays editable during export (phase idle, look edited while job 1 renders)")
            let deadline = Date().addingTimeInterval(180)
            while queue.hasPending, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            let states = queue.jobs.map { "\($0.state)" }
            guard queue.jobs[0].state == .done, queue.jobs[1].state == .cancelled, queue.jobs[2].state == .done,
                  !FileManager.default.fileExists(atPath: second.path),
                  queue.jobs[0].finished! <= queue.jobs[2].started! else { throw RecorderError.message("Unexpected queue result: \(states)") }
            func corner(_ url: URL) async throws -> (Int,Int,Int) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                let image = try await generator.image(at: CMTime(seconds: 0.5,preferredTimescale: 600)).image
                let ctx = CGContext(data: nil,width: 4,height: 4,bitsPerComponent: 8,bytesPerRow: 16,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image.cropping(to: CGRect(x: 4,y: 4,width: 4,height: 4))!,in: CGRect(x: 0,y: 0,width: 4,height: 4))
                let b = ctx.data!.assumingMemoryBound(to: UInt8.self); return (Int(b[0]),Int(b[1]),Int(b[2]))
            }
            let red = try await corner(first), green = try await corner(third)
            guard red.0 > 180, red.1 < 60, green.1 > 180, green.0 < 60 else { throw RecorderError.message("Exports do not match their snapshots: \(red) / \(green)") }
            log("PASS jobs ran in order, waiting job cancelled without a file, each export rendered its own snapshot (job 1 corner RGB \(red), job 3 \(green))")
            log("DONE")
        } catch { log("FAIL \(error.localizedDescription)") }
    }
}
