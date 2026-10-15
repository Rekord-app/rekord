import AppKit
import SwiftUI
import RecorderCore

/// Background MP4 exports. Each job renders a snapshot of the project, so editing and recording continue
/// while it runs. Jobs run one after another: a single export already uses all cores.
@MainActor final class ExportQueue: ObservableObject {
    enum State: Equatable { case waiting, running, done, failed(String), cancelled }
    struct Job: Identifiable {
        let id = UUID()
        let project: Project
        let directory: URL
        let destination: URL
        let height: Int
        let fps: Int
        var progress = 0.0
        var state = State.waiting
        var started: Date?
        var finished: Date?
        var summary: String { "\(project.style.format.rawValue) · \(height == 2160 ? "4K" : "\(height)p")\(fps)" }
    }
    @Published private(set) var jobs: [Job] = []
    private var running: Task<Void,Never>?
    private var runningID: UUID?
    var active: Job? { jobs.first { $0.state == .running } ?? jobs.first { $0.state == .waiting } }
    var hasPending: Bool { jobs.contains { $0.state == .running || $0.state == .waiting } }

    func enqueue(project: Project,directory: URL,destination: URL,height: Int,fps: Int) {
        jobs.append(Job(project: project,directory: directory,destination: destination,height: height,fps: fps))
        startNext()
    }
    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].state == .waiting { jobs[i].state = .cancelled }
        else if jobs[i].state == .running, runningID == id { running?.cancel() }
    }
    func cancelAll() {
        for i in jobs.indices where jobs[i].state == .waiting { jobs[i].state = .cancelled }
        running?.cancel()
    }
    func clearFinished() { jobs.removeAll { $0.state != .running && $0.state != .waiting } }
    func reveal(_ id: UUID) { if let job = jobs.first(where: { $0.id == id }) { NSWorkspace.shared.activateFileViewerSelecting([job.destination]) } }

    private func startNext() {
        guard running == nil, let i = jobs.firstIndex(where: { $0.state == .waiting }) else { return }
        jobs[i].state = .running; jobs[i].started = Date()
        let job = jobs[i]; runningID = job.id
        running = Task {
            var outcome = State.done
            do {
                try await MovieExporter.export(project: job.project,directory: job.directory,to: job.destination,height: job.height,fps: job.fps) { progress in
                    Task { @MainActor [weak self] in self?.update(job.id) { $0.progress = max($0.progress,progress) } }
                }
            } catch is CancellationError { outcome = .cancelled }
            catch { outcome = .failed(error.localizedDescription) }
            update(job.id) { $0.state = outcome; $0.finished = Date(); if outcome == .done { $0.progress = 1 } }
            running = nil; runningID = nil
            startNext()
        }
    }
    private func update(_ id: UUID,_ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }
}

/// Compact list of export jobs with progress, cancel and reveal.
struct ExportQueueView: View {
    @ObservedObject var queue: ExportQueue
    var body: some View {
        if !queue.jobs.isEmpty {
            VStack(alignment: .leading,spacing: 8) {
                HStack {
                    Text("Exporte").font(.system(size: 12,weight: .semibold))
                    Spacer()
                    if queue.jobs.contains(where: { $0.state != .running && $0.state != .waiting }) { Button("Erledigte entfernen") { queue.clearFinished() }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }
                ForEach(queue.jobs) { job in
                    VStack(alignment: .leading,spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: icon(job.state)).foregroundStyle(color(job.state))
                            Text(job.destination.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if job.state == .running || job.state == .waiting {
                                Button { queue.cancel(job.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Export abbrechen")
                            } else if job.state == .done {
                                Button { queue.reveal(job.id) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).help("Im Finder zeigen")
                            }
                        }
                        if job.state == .running { ProgressView(value: job.progress).controlSize(.small) }
                        Text(detail(job)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(8).background(StudioTheme.fill,in: RoundedRectangle(cornerRadius: 8,style: .continuous))
                }
            }.font(.caption)
        }
    }
    private func detail(_ job: ExportQueue.Job) -> String {
        switch job.state {
        case .waiting: return "\(job.summary) · wartet"
        case .running: return "\(job.summary) · \(Int(job.progress*100)) %"
        case .done: return "\(job.summary) · fertig\(job.started.flatMap { s in job.finished.map { String(format: " in %.0f s",$0.timeIntervalSince(s)) } } ?? "")"
        case .failed(let message): return "Fehlgeschlagen: \(message)"
        case .cancelled: return "\(job.summary) · abgebrochen"
        }
    }
    private func icon(_ state: ExportQueue.State) -> String {
        switch state { case .waiting: return "clock"; case .running: return "arrow.down.circle"; case .done: return "checkmark.circle.fill"; case .failed: return "exclamationmark.triangle.fill"; case .cancelled: return "xmark.circle" }
    }
    private func color(_ state: ExportQueue.State) -> Color {
        switch state { case .done: return StudioTheme.success; case .failed: return StudioTheme.warning; case .running: return StudioTheme.accent; default: return StudioTheme.textSecondary }
    }
}

/// Status-bar summary of the running export; click opens the export tab.
struct ExportStatusIndicator: View {
    @ObservedObject var queue: ExportQueue
    let open: () -> Void
    var body: some View {
        if let job = queue.active {
            let waiting = queue.jobs.filter { $0.state == .waiting }.count
            Button(action: open) {
                HStack(spacing: 6) {
                    ProgressView(value: job.progress).controlSize(.mini).frame(width: 60)
                    Text("Export \(Int(job.progress*100)) %\(waiting > (job.state == .waiting ? 1 : 0) ? " · \(waiting) wartend" : "")").font(.system(size: 10)).monospacedDigit()
                }
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("Exporte anzeigen")
        }
    }
}
