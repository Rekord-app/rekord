import Foundation
@preconcurrency import AVFoundation
import Speech
import RecorderCore

/// Local transcription with Apple's on-device `SpeechTranscriber` (macOS 26). Chosen over whisper.cpp large-v3
/// after a measurement on 14.10.2026: 15 s instead of 4:35 min for 10 min of German speech per track, which
/// keeps the summary within 90 s after Stop. Whisper recognized proper names better; the summary step corrects
/// clearly misheard glossary terms. Sentences come from word time ranges; speakers come from the track.
enum MeetingTranscriber {
    static var engine: String { "Apple SpeechTranscriber (on-device)" }
    static var available: Bool { if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }; return false }

    static func transcribe(directory: URL,meeting: Meeting) async throws -> Transcript {
        guard #available(macOS 26, *) else { throw RecorderError.message("Die lokale Transkription braucht macOS 26 oder neuer.") }
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "de-DE")) ?? Locale(identifier: "de-DE")
        var tracks: [(URL,Speaker,Double)] = [(directory.appendingPathComponent(MeetingFile.microphone),.me,meeting.microphoneOffset)]
        if meeting.hasSystemAudio { tracks.append((directory.appendingPathComponent(MeetingFile.system),.other,meeting.systemOffset)) }
        // Both tracks in parallel; each runs its own analyzer.
        let sentences = try await withThrowingTaskGroup(of: [TranscriptSentence].self) { group in
            for (url,speaker,offset) in tracks where FileManager.default.fileExists(atPath: url.path) {
                group.addTask { Transcript.sentences(from: try await words(in: url,locale: locale),speaker: speaker,offset: offset) }
            }
            var all: [[TranscriptSentence]] = []
            for try await part in group { all.append(part) }
            return all
        }
        let merged = Transcript.merged(sentences),cleaned = Transcript.removingEcho(merged)
        return Transcript(engine: engine,locale: locale.identifier,sentences: cleaned,echoRemoved: merged.count-cleaned.count)
    }

    @available(macOS 26, *)
    static func words(in url: URL,locale: Locale) async throws -> [TranscriptWord] {
        let transcriber = SpeechTranscriber(locale: locale,transcriptionOptions: [],reportingOptions: [],attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return [] }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task { () -> [TranscriptWord] in
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                let text = result.text
                for run in text.runs {
                    let piece = String(text[run.range].characters)
                    guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    if let range = run.audioTimeRange {
                        words.append(TranscriptWord(text: piece,start: range.start.seconds,end: range.end.seconds))
                    } else if !words.isEmpty {
                        words[words.count-1].text += piece   // punctuation without its own time range
                    } else {
                        words.append(TranscriptWord(text: piece,start: result.range.start.seconds,end: result.range.end.seconds))
                    }
                }
            }
            return words
        }
        try await analyzer.start(inputAudioFile: file,finishAfterFile: true)
        return try await collect.value
    }
}
