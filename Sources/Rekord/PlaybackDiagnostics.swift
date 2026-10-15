import AppKit
@preconcurrency import AVFoundation
import RecorderCore

/// `--playback-check <dir> --project <recording.rekord>`: exercises the real editor store on a copy of a
/// recording. Measures frames the AVPlayer item actually delivers during playback, scrubbing into removed
/// ranges, cut edits (composition rebuild) and look edits (live compositor swap). No permissions needed.
@MainActor enum PlaybackDiagnostics {
    static func run(arguments: [String]) async {
        guard let i = arguments.firstIndex(of: "--playback-check"),arguments.count > i+1,
              let p = arguments.firstIndex(of: "--project"),arguments.count > p+1 else { return }
        let root = URL(fileURLWithPath: arguments[i+1])
        var lines: [String] = []
        func log(_ value: String) {
            lines.append(value)
            try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("playback-report.txt"),atomically: true,encoding: .utf8)
        }
        func wait(_ seconds: Double,until condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if condition() { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
            return condition()
        }
        // The store records opened projects; keep the user's recent list untouched.
        let recent = UserDefaults.standard.object(forKey: "recentProjects")
        defer { UserDefaults.standard.set(recent,forKey: "recentProjects") }
        do {
            try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            log("START editor playback check \(Date().ISO8601Format())")
            log("INFO cameras: \(CaptureDevices.cameras().map(\.name).joined(separator: " | ")) · default \(CaptureDevices.camera(id: "")?.localizedName ?? "none")")
            log("INFO microphones: \(CaptureDevices.microphones().map(\.name).joined(separator: " | ")) · default \(CaptureDevices.microphone(id: "")?.localizedName ?? "none")")
            let copy = root.appendingPathComponent("project.rekord")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[p+1]),to: copy)
            let store = EditorStore()
            store.open(copy)
            guard await wait(15,until: { store.playerReady }),let project = store.project,let item = store.player.currentItem else { throw RecorderError.message("Editor playback did not become ready") }
            log("PASS player ready · \(project.width)×\(project.height) source, \(project.fps) fps, \(String(format: "%.2f",project.editedDuration)) s")

            // Real-time playback: count distinct frames the player item delivers.
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output)
            store.seekEdited(0)
            _ = await wait(3) { abs(store.player.currentTime().seconds) < 0.02 }
            let window = min(3.0,max(1.0,project.editedDuration-0.4))
            let pressed = Date()
            store.togglePlayback()
            guard await wait(3,until: { store.player.timeControlStatus == .playing && store.player.currentTime().seconds > 0.001 }) else { throw RecorderError.message("Player did not start") }
            let startLatency = Date().timeIntervalSince(pressed)
            let clockStart = Date(), mediaStart = store.player.currentTime().seconds
            var frames = 0, size = (0,0), last = -1.0, gaps: [Double] = []
            while Date().timeIntervalSince(clockStart) < window {
                let now = output.itemTime(forHostTime: CACurrentMediaTime())
                if output.hasNewPixelBuffer(forItemTime: now),let buffer = output.copyPixelBuffer(forItemTime: now,itemTimeForDisplay: nil) {
                    frames += 1; size = (CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer))
                    if last >= 0 { gaps.append(now.seconds-last) }; last = now.seconds
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let mediaAdvance = store.player.currentTime().seconds-mediaStart, wall = Date().timeIntervalSince(clockStart)
            store.pause()
            let expected = Double(min(60,project.fps))
            let delivered = Double(frames)/wall, worstGap = gaps.max() ?? 0
            let report = String(format: "start latency %.0f ms · %.1f fps delivered of %.0f (%d frames in %.2f s), media advanced %.2f s, worst frame gap %.0f ms, frame %d×%d",startLatency*1000,delivered,expected,frames,wall,mediaAdvance,worstGap*1000,size.0,size.1)
            guard delivered >= expected*0.9, abs(mediaAdvance-wall) < 0.15, worstGap < 3.5/expected, startLatency < 1 else { throw RecorderError.message("Playback not real time: \(report)") }
            guard abs(store.editedTime-store.player.currentTime().seconds) < 0.1, !store.playing else { throw RecorderError.message("UI time does not follow player") }
            log("PASS real-time playback · \(report)")
            // Real time across the first zoom, where the frames are motion-blurred.
            if let zoom = project.zooms.first, zoom.start+0.2 < project.editedDuration {
                let start = max(0,zoom.start-0.2), window = min(2.0,project.editedDuration-start-0.1)
                store.seekEdited(start); _ = await wait(3) { abs(store.player.currentTime().seconds-start) < 0.02 }
                _ = output.copyPixelBuffer(forItemTime: store.player.currentTime(),itemTimeForDisplay: nil)
                store.togglePlayback()
                guard await wait(3,until: { store.player.currentTime().seconds > start+0.001 }) else { throw RecorderError.message("Player did not start at zoom") }
                let begin = Date(), media = store.player.currentTime().seconds
                var zoomFrames = 0, zoomGaps: [Double] = [], previous = -1.0
                while Date().timeIntervalSince(begin) < window {
                    let now = output.itemTime(forHostTime: CACurrentMediaTime())
                    if output.hasNewPixelBuffer(forItemTime: now), output.copyPixelBuffer(forItemTime: now,itemTimeForDisplay: nil) != nil {
                        zoomFrames += 1; if previous >= 0 { zoomGaps.append(now.seconds-previous) }; previous = now.seconds
                    }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                let elapsed = Date().timeIntervalSince(begin), advanced = store.player.currentTime().seconds-media
                store.pause()
                let rate = Double(zoomFrames)/elapsed
                let summary = String(format: "%.1f fps delivered across the zoom (%.2f–%.2f s), media advanced %.2f s in %.2f s, worst frame gap %.0f ms",rate,start,start+window,advanced,elapsed,(zoomGaps.max() ?? 0)*1000)
                guard rate >= expected*0.9, abs(advanced-elapsed) < 0.15 else { throw RecorderError.message("Zoom playback not real time: \(summary)") }
                log("PASS motion-blurred zoom playback · \(summary)")
            }
            // Resume after pause (audio route already running) and after a scrub elsewhere.
            for (label,target) in [("resume",nil),("after scrub",0.5)] as [(String,Double?)] {
                if let target { store.seekEdited(target); _ = await wait(3) { abs(store.player.currentTime().seconds-target) < 0.02 } }
                let begin = Date(), media = store.player.currentTime().seconds
                store.togglePlayback()
                guard await wait(3,until: { store.player.currentTime().seconds > media+0.001 }) else { throw RecorderError.message("Player did not \(label)") }
                log(String(format: "INFO start latency %@: %.0f ms",label,Date().timeIntervalSince(begin)*1000))
                try await Task.sleep(nanoseconds: 300_000_000); store.pause()
            }

            // Cut edit rebuilds the composition; scrubbing into the removed range shows a marked still.
            guard project.duration > 2.5 else { log("SKIP cut/removed-range check: recording shorter than 2.5 s"); return finish() }
            let removedStart = project.duration*0.4, removedEnd = project.duration*0.6
            store.edit { $0.cuts = [Cut(start: 0,end: removedStart),Cut(start: removedEnd,end: $0.duration)] }
            guard await wait(15,until: { store.playerReady && store.player.currentItem !== item }),let edited = store.project else { throw RecorderError.message("Cut edit did not rebuild playback") }
            guard let duration = (store.player.currentItem?.asset as? AVComposition)?.duration.seconds, abs(duration-edited.editedDuration) < 0.05 else { throw RecorderError.message("Rebuilt composition has wrong duration") }
            store.seekSource((removedStart+removedEnd)/2)
            guard await wait(10,until: { store.removedFrame != nil }) else { throw RecorderError.message("Removed range shows no marked still") }
            store.seekSource(removedEnd+0.3)
            guard store.removedFrame == nil, abs(store.editedTime-(removedStart+0.3)) < 0.01 else { throw RecorderError.message("Seek after removed range maps incorrectly (\(store.editedTime))") }
            _ = await wait(5) { abs(store.player.currentTime().seconds-store.editedTime) < 0.02 }
            log(String(format: "PASS cut edit rebuilds playback (%.2f s), removed range shows marked original still, retained source time maps to %.2f s",edited.editedDuration,store.editedTime))

            // Look edits swap the compositor on the live item.
            let lookOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            store.player.currentItem?.add(lookOutput)
            // Check the background at an unzoomed moment: while zoomed, the card covers the frame corners.
            store.seekEdited(0)
            _ = await wait(5) { abs(store.player.currentTime().seconds) < 0.02 }
            store.edit { var backdrop = BackdropSettings(kind: .solid); backdrop.start = RGB(0,1,0); $0.style.backdrop = backdrop; $0.style.padding = 0.12 }
            let at = store.player.currentTime()
            var corner: [UInt8] = []
            _ = await wait(5) {
                guard let buffer = lookOutput.copyPixelBuffer(forItemTime: at,itemTimeForDisplay: nil) else { store.seekEdited(store.editedTime); return false }
                CVPixelBufferLockBaseAddress(buffer,.readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
                let pixel = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self).advanced(by: 8*CVPixelBufferGetBytesPerRow(buffer)+8*4)
                corner = [pixel[0],pixel[1],pixel[2]]
                return corner[1] > 240 && corner[0] < 15 && corner[2] < 15
            }
            guard corner.count == 3, corner[1] > 240, corner[0] < 15, corner[2] < 15 else { throw RecorderError.message("Look edit did not reach playback (corner BGR \(corner))") }
            log("PASS look edit reaches paused playback frame (corner BGR \(corner))")
            return finish()
        } catch { log("FAIL \(error.localizedDescription)") }
        func finish() { log("DONE") }
    }
}
