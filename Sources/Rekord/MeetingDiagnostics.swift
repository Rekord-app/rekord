import AppKit
import AVFoundation
import RecorderCore

/// `--meeting-check <dir> --audio <file> [--no-summary]`: real meeting acceptance without a human caller.
/// Records while `afplay` plays a German test dialogue (system audio → tap), then transcribes and
/// summarizes and checks the result.
/// Meetings go to `<dir>/Meetings`, so the user's list stays untouched. Report: `<dir>/meeting-report.txt`.
@MainActor enum MeetingDiagnostics {
    static func run(arguments: [String]) async {
        if let r = arguments.firstIndex(of: "--meeting-reprocess"),arguments.count > r+1 { await reprocess(URL(fileURLWithPath: arguments[r+1])); return }
        if let r = arguments.firstIndex(of: "--meeting-auto-check"),arguments.count > r+1,let a = arguments.firstIndex(of: "--audio"),arguments.count > a+1 {
            await autoCheck(root: URL(fileURLWithPath: arguments[r+1]),audio: URL(fileURLWithPath: arguments[a+1])); return
        }
        guard let i = arguments.firstIndex(of: "--meeting-check"),arguments.count > i+1,
              let a = arguments.firstIndex(of: "--audio"),arguments.count > a+1 else { return }
        let root = URL(fileURLWithPath: arguments[i+1]),audio = URL(fileURLWithPath: arguments[a+1])
        var lines: [String] = []
        func log(_ value: String) { lines.append(value); try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("meeting-report.txt"),atomically: true,encoding: .utf8); print(value) }
        func check(_ ok: Bool,_ text: String) { log("\(ok ? "PASS" : "FAIL") \(text)") }
        do {
            try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            log("START meeting acceptance \(Date().ISO8601Format()) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
            if arguments.contains("--no-summary") { log("INFO summary skipped (--no-summary)") }
            else { check(store.hasAPIKey,"Claude key present in Keychain") }

            // Microphone + system audio while the test dialogue plays; names are left for the summary to fill.
            store.start()
            for _ in 0..<100 where store.phase != .recording { try await Task.sleep(nanoseconds: 100_000_000) }
            guard store.phase == .recording,let directory = store.selected else { log("FAIL recording did not start: \(store.error ?? "unknown")"); return }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let player = Process(); player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); player.arguments = [audio.path]
            try player.run()
            var connections = Set<String>()
            while player.isRunning { connections.formUnion(remoteEndpoints()); try await Task.sleep(nanoseconds: 1_000_000_000) }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let stopped = Date()
            store.stop()
            for _ in 0..<1800 where store.phase != .idle { connections.formUnion(remoteEndpoints()); try await Task.sleep(nanoseconds: 100_000_000) }
            log("INFO processing took \(String(format: "%.1f",Date().timeIntervalSince(stopped))) s")
            let meeting = try Meeting.load(from: directory)
            check(meeting.company.contains("Wagner") && meeting.contact.contains("Petra"),"named from the conversation: \(meeting.displayTitle) · \(meeting.contact) · \(meeting.company)")
            log("INFO meeting status \(meeting.status.rawValue)\(meeting.error.map { " · \($0)" } ?? "")")
            let mic = directory.appendingPathComponent(MeetingFile.microphone),system = directory.appendingPathComponent(MeetingFile.system)
            let micSeconds = try duration(mic),systemSeconds = try duration(system)
            log(String(format: "INFO tracks: microphone %.1f s, system %.1f s, meeting %.1f s, offsets mic %.3f / system %.3f",micSeconds,systemSeconds,meeting.duration,meeting.microphoneOffset,meeting.systemOffset))
            check(meeting.hasSystemAudio,"system audio track written")
            check(abs(micSeconds-meeting.duration) < 1.5 && abs(systemSeconds+meeting.systemOffset-meeting.duration) < 1.5,"both tracks cover the meeting (±1.5 s)")
            let peak = try peakLevel(system)
            check(peak > 0.01,String(format: "system track is not silent (peak %.3f)",peak))
            if let transcript = try? Transcript.load(from: directory) {
                let other = transcript.sentences.filter { $0.speaker == .other },mine = transcript.sentences.filter { $0.speaker == .me }
                log("INFO transcript: \(other.count) sentences Gegenüber, \(mine.count) sentences Ich, \(transcript.echoRemoved ?? 0) removed as speaker echo")
                check(!other.isEmpty,"dialogue transcribed on the system track")
                if let first = other.first,let voice = try firstVoice(system) {
                    // SpeechTranscriber segment ranges include leading silence (~1 s), so allow 1.5 s.
                    check(abs(first.start-(voice+meeting.systemOffset)) < 1.5,String(format: "timeline: first sentence at %.2f s, first voice in system track at %.2f s (+ offset %.2f)",first.start,voice,meeting.systemOffset))
                }
                log("INFO first sentences: " + other.prefix(3).map(\.text).joined(separator: " | "))
            } else { log("FAIL no transcript") }
            if !arguments.contains("--no-summary") {
                if let summary = try? MeetingSummary.load(from: directory) {
                    check(true,"summary written · interest \(summary.interest)/5 · next step: \(summary.nextStep.action) \(summary.nextStep.date)")
                    log("INFO company: \(summary.company) · pain: \(summary.mainPain) · budget: \(summary.budgetSignal)")
                    log("INFO objections: " + summary.objections.map { "„\($0.quote)“ [\($0.timestamp)]" }.joined(separator: " "))
                } else { log("FAIL no summary") }
                if let seconds = meeting.processingSeconds { check(seconds <= 90,"transcript and summary within 90 s after Stop (\(seconds) s)") }
            }
            log("INFO remote endpoints during take and processing: \(connections.isEmpty ? "none" : connections.sorted().joined(separator: ", "))")
            check(connections.allSatisfy { $0.contains(":443") },"only HTTPS connections (Claude API), no other traffic")

            log("DONE")
        } catch { log("FAIL \(error.localizedDescription)") }
    }
    /// `--meeting-auto-check <dir> --audio <file>`: no click. A stand-in meeting app (ffmpeg capturing the
    /// microphone for 20 s) must make Rekord start by itself, the test dialogue plays as the other side, and
    /// Rekord must stop by itself after the „call“ ends and produce the transcript.
    static func autoCheck(root: URL,audio: URL) async {
        var lines: [String] = []
        func log(_ value: String) { lines.append(value); try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("auto-report.txt"),atomically: true,encoding: .utf8); print(value) }
        func check(_ ok: Bool,_ text: String) { log("\(ok ? "PASS" : "FAIL") \(text)") }
        do {
            try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            log("START automatic call detection \(Date().ISO8601Format())")
            if #available(macOS 14.2, *) {
                log("INFO microphone in use before the test: \(MeetingDetector.activeCall().map { "\($0.app) – \($0.title)" } ?? "no meeting app")")
            }
            let store = MeetingStore(root: root.appendingPathComponent("Meetings"))
            store.autoRecord = true
            store.updateDetector(testProcessName: "ffmpeg")
            let begin = Date()
            let caller = Process(); caller.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            caller.arguments = ["-loglevel","error","-f","avfoundation","-i",":default","-y",root.appendingPathComponent("caller.wav").path]
            caller.standardInput = FileHandle.nullDevice
            try caller.run()
            let callerStart = Date()
            for _ in 0..<150 where store.phase != .recording { try await Task.sleep(nanoseconds: 100_000_000) }
            check(store.phase == .recording,String(format: "recording started by itself after %.1f s",Date().timeIntervalSince(begin)))
            let player = Process(); player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); player.arguments = ["-t","14",audio.path]
            try player.run()
            // The „call“ ends after 20 s: the stand-in app releases the microphone.
            while caller.isRunning, Date().timeIntervalSince(callerStart) < 20 { try await Task.sleep(nanoseconds: 200_000_000) }
            kill(caller.processIdentifier,SIGKILL)   // SIGTERM is ignored while AVFoundation waits for audio
            let ended = Date()
            for _ in 0..<300 where store.phase == .recording { try await Task.sleep(nanoseconds: 100_000_000) }
            check(store.phase != .recording,String(format: "recording stopped by itself %.1f s after the call ended",Date().timeIntervalSince(ended)))
            for _ in 0..<1200 where store.phase != .idle { try await Task.sleep(nanoseconds: 100_000_000) }
            guard let directory = store.selected else { log("FAIL no meeting"); return }
            let meeting = try Meeting.load(from: directory)
            check(meeting.app == "Test" && meeting.hasSystemAudio,"meeting tagged with the detected app, both tracks")
            let transcript = try? Transcript.load(from: directory)
            check((transcript?.sentences.filter { $0.speaker == .other }.count ?? 0) > 0,"transcript ready: \(transcript?.sentences.first?.text ?? "–")")
            log("INFO status \(meeting.status.rawValue) · title \(meeting.displayTitle) · \(meeting.processingSeconds.map { "\($0) s" } ?? "")")
            log("DONE")
        } catch { log("FAIL \(error.localizedDescription)") }
    }
    /// `--meeting-reprocess <meeting dir>`: transcribe and summarize an existing meeting again and time it
    /// (for long calls without recording them in real time). Report: `<meeting dir>/reprocess-report.txt`.
    static func reprocess(_ directory: URL) async {
        let store = MeetingStore(root: directory.deletingLastPathComponent())
        let start = Date()
        guard let meeting = try? Meeting.load(from: directory) else { return }
        await store.process(directory: directory,meeting: meeting,since: start,retranscribe: true)
        let done = try? Meeting.load(from: directory)
        let transcript = try? Transcript.load(from: directory)
        let report = [String(format: "processing %.1f s for %.0f s of audio",Date().timeIntervalSince(start),meeting.duration),
                      "status \(done?.status.rawValue ?? "?") \(done?.error ?? "")",
                      "sentences \(transcript?.sentences.count ?? 0), echo removed \(transcript?.echoRemoved ?? 0)",
                      "summary \((try? MeetingSummary.load(from: directory)) != nil ? "written" : "missing")"].joined(separator: "\n")
        try? report.write(to: directory.appendingPathComponent("reprocess-report.txt"),atomically: true,encoding: .utf8)
        print(report)
    }
    /// Seconds until the first sample above -34 dBFS.
    static func firstVoice(_ url: URL) throws -> Double? {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData?[0] else { return nil }
        for index in 0..<Int(buffer.frameLength) where abs(data[index]) > 0.02 { return Double(index)/file.processingFormat.sampleRate }
        return nil
    }
    static func duration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url); return Double(file.length)/file.fileFormat.sampleRate
    }
    static func peakLevel(_ url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,frameCapacity: AVAudioFrameCount(file.length)) else { return 0 }
        try file.read(into: buffer)
        var peak: Float = 0
        for channel in 0..<Int(file.processingFormat.channelCount) { if let data = buffer.floatChannelData?[channel] { for index in 0..<Int(buffer.frameLength) { peak = max(peak,abs(data[index])) } } }
        return peak
    }
    /// Remote addresses of this process's open TCP connections (lsof), to check that only the Claude API is contacted.
    static func remoteEndpoints() -> Set<String> {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a","-i","TCP","-n","-P","-p","\(ProcessInfo.processInfo.processIdentifier)"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),as: UTF8.self)
        return Set(output.split(separator: "\n").compactMap { line in line.split(separator: " ").first(where: { $0.contains("->") }).map { String($0.split(separator: ">").last ?? "") } })
    }
}
