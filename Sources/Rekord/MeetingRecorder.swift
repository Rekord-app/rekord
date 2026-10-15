import Foundation
@preconcurrency import AVFoundation
import RecorderCore

/// Meeting mode capture: own microphone (`microphone.m4a`) and the system audio
/// of the call (`system.m4a`) as two separate tracks. Both are timed on the host clock so the transcript can
/// put them on one timeline.
final class MeetingRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.sapunov.rekord.meeting",qos: .userInitiated)
    private var session: AVCaptureSession?
    private var microphone: AudioSink?
    private var tap: AnyObject?
    private var startHostSeconds = 0.0
    private var recording = false
    private(set) var microphoneLevel = 0.0
    var systemLevel: Double {
        if #available(macOS 14.2, *), let tap = tap as? SystemAudioTap { return min(1,Double(tap.currentLevel)*1.6) }
        return 0
    }

    func start(directory: URL,systemAudio: Bool,microphoneID: String) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecorderError.message("Mikrofonzugriff fehlt. In Datenschutz & Sicherheit → Mikrofon freigeben.") }
        guard let device = CaptureDevices.microphone(id: microphoneID) else { throw RecorderError.message("Kein Mikrofon angeschlossen.") }
        let session = AVCaptureSession(); session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecorderError.message("Mikrofon kann nicht geöffnet werden.") }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput(); output.setSampleBufferDelegate(self,queue: queue)
        guard session.canAddOutput(output) else { throw RecorderError.message("Mikrofon-Ausgabe nicht verfügbar.") }
        session.addOutput(output); session.commitConfiguration()
        let sink = try AudioSink(url: directory.appendingPathComponent(MeetingFile.microphone))
        startHostSeconds = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        await withCheckedContinuation { continuation in queue.async { self.microphone = sink; self.recording = true; continuation.resume() } }
        if systemAudio {
            guard #available(macOS 14.2, *) else { throw RecorderError.message("Systemton im Meeting-Modus braucht macOS 14.2 oder neuer.") }
            let tap = SystemAudioTap()
            do { try tap.start(url: directory.appendingPathComponent(MeetingFile.system)) }
            catch { await abort(); throw error }
            self.tap = tap
        }
        await withCheckedContinuation { continuation in queue.async { session.startRunning(); continuation.resume() } }
        self.session = session
    }
    func captureOutput(_ output: AVCaptureOutput,didOutput sampleBuffer: CMSampleBuffer,from connection: AVCaptureConnection) {
        microphoneLevel = Rekord.microphoneLevel(connection)
        guard recording else { return }
        microphone?.append(sampleBuffer)
    }
    struct Result { var duration: Double; var microphoneOffset: Double; var systemOffset: Double; var hasSystemAudio: Bool; var warning: String? }
    func stop() async throws -> Result {
        let end = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        var systemOffset = 0.0, hasSystem = false, warning: String?
        if #available(macOS 14.2, *), let tap = tap as? SystemAudioTap {
            tap.stop()
            if let failure = tap.failure { warning = "Systemton unvollständig: \(failure.localizedDescription)" }
            if let start = tap.startSeconds { systemOffset = start-startHostSeconds; hasSystem = true }
            if tap.maximumLevel < 0.0005 {
                warning = "Die Systemton-Spur ist stumm. Entweder lief kein Ton, oder Rekord fehlt die Freigabe unter Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme → Nur Systemaudio."
            }
        }
        tap = nil
        let sink: AudioSink? = await withCheckedContinuation { continuation in queue.async {
            self.recording = false; self.session?.stopRunning()
            let sink = self.microphone; self.microphone = nil
            continuation.resume(returning: sink)
        } }
        session = nil
        guard let sink else { throw RecorderError.message("Keine aktive Meeting-Aufnahme.") }
        // A failing microphone must not cost the other side's track: keep the call with the system audio alone.
        do { try await sink.finish() }
        catch {
            guard hasSystem else { throw error }
            try? FileManager.default.removeItem(at: sink.writer.outputURL)
            warning = [warning,"Deine Mikrofonspur konnte nicht gesichert werden (\(error.localizedDescription)); das Transkript enthält nur die Gegenseite."].compactMap { $0 }.joined(separator: " ")
        }
        // The timeline starts with the first real sample of either track (device start-up is not counted).
        let microphoneStart = sink.firstTime?.seconds ?? startHostSeconds
        let systemStart = hasSystem ? startHostSeconds+systemOffset : microphoneStart
        let zero = min(microphoneStart,systemStart)
        return Result(duration: end-zero,microphoneOffset: microphoneStart-zero,systemOffset: hasSystem ? systemStart-zero : 0,hasSystemAudio: hasSystem,warning: warning)
    }
    func abort() async {
        if #available(macOS 14.2, *), let tap = tap as? SystemAudioTap { tap.stop() }
        tap = nil
        await withCheckedContinuation { continuation in queue.async {
            self.recording = false; self.session?.stopRunning(); self.microphone?.writer.cancelWriting(); self.microphone = nil
            continuation.resume()
        } }
        session = nil
    }
}
