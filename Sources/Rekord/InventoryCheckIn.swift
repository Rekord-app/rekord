import AppKit
import SwiftUI
import AVFoundation
import RecorderCore

@MainActor final class InventoryCheckInPanel: ObservableObject {
    @Published var question = ""
    @Published var context = ""
    @Published var answer = ""
    @Published var recording = false
    @Published var transcribing = false
    @Published var error = ""
    private var panel: NSPanel?, audio: AVAudioRecorder?, audioURL: URL?, expiry: Timer?, voiceLimit: Timer?
    private var completion: ((String,String) -> Void)?
    private var generation = UUID()
    var visible: Bool { panel != nil }
    func show(question: String,context: String,completion: @escaping (String,String) -> Void) {
        guard !visible else { return }
        self.question = question; self.context = context; self.completion = completion; answer = ""; error = ""; generation = UUID()
        let panel = NSPanel(contentRect: CGRect(x: 0,y: 0,width: 380,height: 260),styleMask: [.titled,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.title = "Kurze Rückfrage"; panel.isReleasedWhenClosed = false; panel.level = .floating; panel.hidesOnDeactivate = false; panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces]; panel.contentView = NSHostingView(rootView: InventoryQuestionView(model: self))
        let frame = NSScreen.main?.visibleFrame ?? .zero; panel.setFrameOrigin(CGPoint(x: frame.maxX-404,y: frame.minY+24)); self.panel = panel; panel.orderFrontRegardless()
        expiry = Timer.scheduledTimer(withTimeInterval: 120,repeats: false) { [weak self] _ in Task { @MainActor in self?.finish("skipped") } }
    }
    func startVoice() async {
        guard visible,!recording,!transcribing else { return }
        let token = generation
        guard #available(macOS 26, *) else { error = "Sprache braucht macOS 26. Bitte tippen."; return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { error = "Mikrofon bitte in den Systemeinstellungen freigeben oder tippen."; return }
        guard visible,generation == token,!recording,!transcribing else { return }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("rekord-checkin-\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(url: url,settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,AVSampleRateKey: 44100,AVNumberOfChannelsKey: 1,AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            guard recorder.record() else { throw RecorderError.message("Mikrofon konnte nicht starten.") }
            audio = recorder; audioURL = url; recording = true
            voiceLimit = Timer.scheduledTimer(withTimeInterval: 60,repeats: false) { [weak self] _ in Task { @MainActor in await self?.stopVoice() } }
        } catch { self.error = error.localizedDescription }
    }
    func stopVoice() async {
        guard recording, let url = audioURL else { return }; audio?.stop(); audio = nil; recording = false; voiceLimit?.invalidate(); transcribing = true
        let token = generation
        defer { try? FileManager.default.removeItem(at: url); if generation == token { transcribing = false; audioURL = nil } }
        do {
            guard #available(macOS 26, *) else { return }
            let words = try await MeetingTranscriber.words(in: url,locale: Locale(identifier: "de-DE"))
            guard generation == token,visible else { return }
            answer = SensitiveText.masked(words.map(\.text).joined(separator: " ")); finish("voice")
        } catch { if generation == token { self.error = error.localizedDescription } }
    }
    func finish(_ kind: String) { let action = completion, text = answer; cancel(); action?(text,kind) }
    func cancel() {
        generation = UUID(); expiry?.invalidate(); voiceLimit?.invalidate(); audio?.stop(); audio = nil
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }; audioURL = nil
        recording = false; transcribing = false; panel?.orderOut(nil); panel = nil; completion = nil
    }
}
private struct InventoryQuestionView: View {
    @ObservedObject var model: InventoryCheckInPanel
    @FocusState private var typing: Bool
    var body: some View {
        VStack(alignment: .leading,spacing: 10) {
            Text(model.context).font(.caption).foregroundStyle(.secondary)
            Text(model.question).font(.headline)
            TextField("Antwort tippen …",text: $model.answer,axis: .vertical).lineLimit(2...4).focused($typing)
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(model.recording ? "Fertig" : "Sprechen") { Task { if model.recording { await model.stopVoice() } else { await model.startVoice() } } }.disabled(model.transcribing)
                Button("Tippen") { typing = true }
                Button("Speichern") { model.finish("typed") }.disabled(model.answer.isEmpty || model.recording || model.transcribing)
            }
            HStack { Button("Später") { model.finish("later") }; Button("Heute nicht mehr") { model.finish("todayOff") } }.font(.caption)
            if model.transcribing { ProgressView("Wird lokal transkribiert …").controlSize(.small) }
        }.padding(18).frame(width: 380)
    }
}
