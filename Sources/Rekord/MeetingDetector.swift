import AppKit
import CoreAudio

/// Notices calls without a click, from what the system already shows (own
/// implementation): a meeting app is capturing the microphone (Core Audio per-process input state, macOS 14.2+)
/// and, for browsers, a window title shows a meeting (Google Meet, Teams, Zoom web). The call has ended when that
/// app releases the microphone. Polls every 2 s; Rekord's own microphone use is ignored.
@available(macOS 14.2, *)
@MainActor final class MeetingDetector {
    struct Call: Equatable { let app: String; let title: String; let pid: pid_t }
    private static let apps: [(prefix: String,name: String)] = [
        ("us.zoom.xos","Zoom"),("com.microsoft.teams","Teams"),("com.tinyspeck.slackmacgap","Slack Huddle"),
        ("com.apple.FaceTime","FaceTime"),("com.apple.avconferenced","Anruf"),("com.cisco.webexmeetingsapp","Webex"),
        ("com.hnc.Discord","Discord"),("net.whatsapp.WhatsApp","WhatsApp"),("ru.keepcoder.Telegram","Telegram"),
    ]
    private static let browsers: [(prefix: String,owner: String)] = [
        ("com.google.Chrome","Google Chrome"),("com.apple.WebKit","Safari"),("com.apple.Safari","Safari"),("company.thebrowser","Arc"),
        ("com.microsoft.edgemac","Microsoft Edge"),("com.brave.Browser","Brave Browser"),("org.mozilla.firefox","Firefox"),
        ("com.vivaldi.Vivaldi","Vivaldi"),("com.operasoftware.Opera","Opera"),("app.zen-browser","Zen"),("com.openai.atlas","ChatGPT Atlas"),
    ]
    var onStart: ((Call) -> Void)?
    var onEnd: ((Call) -> Void)?
    /// Executable name treated as a meeting app (acceptance tests only).
    var testProcessName: String?
    private(set) var current: Call?
    private var candidate: (call: Call,since: Date)?
    private var releasedSince: Date?
    private var timer: Timer?
    /// A call the user stopped or discarded by hand is not picked up again until its app releases the microphone.
    private var ignoredPID: pid_t?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2,repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
    }
    func stop() { timer?.invalidate(); timer = nil; current = nil; candidate = nil }
    func ignoreCurrent() { ignoredPID = current?.pid ?? candidate?.call.pid; current = nil; candidate = nil }

    private func poll() {
        let found = Self.activeCall(testName: testProcessName)
        if let ignoredPID, found?.pid != ignoredPID { self.ignoredPID = nil }
        if let current {
            if found?.pid == current.pid || (found != nil && found?.app == current.app) { releasedSince = nil; return }
            // Microphone released: wait a little (rejoin, device switch) before ending the call.
            let since = releasedSince ?? Date(); releasedSince = since
            if Date().timeIntervalSince(since) >= 6 { self.current = nil; releasedSince = nil; onEnd?(current) }
            return
        }
        guard let found, found.pid != ignoredPID else { candidate = nil; return }
        if let candidate, candidate.call.pid == found.pid {
            if Date().timeIntervalSince(candidate.since) >= 3 { current = found; self.candidate = nil; onStart?(found) }
        } else { candidate = (found,Date()) }
    }

    /// The meeting app currently capturing the microphone, if any.
    static func activeCall(testName: String? = nil) -> Call? {
        let own = ProcessInfo.processInfo.processIdentifier
        for object in SystemAudioTap.processObjects() {
            guard let running: UInt32 = try? SystemAudioTap.value(object,kAudioProcessPropertyIsRunningInput), running != 0,
                  let pid: pid_t = try? SystemAudioTap.value(object,kAudioProcessPropertyPID), pid != own else { continue }
            let bundle = SystemAudioTap.bundleID(object) ?? ""
            if let testName, processName(pid) == testName { return Call(app: "Test",title: "Test-Call",pid: pid) }
            if let app = apps.first(where: { bundle.hasPrefix($0.prefix) }) { return Call(app: app.name,title: windowTitle(owners: [app.name,"zoom.us","Microsoft Teams","FaceTime"]) ?? app.name,pid: pid) }
            if let browser = browsers.first(where: { bundle.hasPrefix($0.prefix) }), let meeting = browserMeeting(owner: browser.owner) {
                return Call(app: meeting.app,title: meeting.title,pid: pid)
            }
        }
        return nil
    }
    /// A browser window whose title shows a web meeting (needs the screen recording permission Rekord already has).
    static func browserMeeting(owner: String) -> (app: String,title: String)? {
        for title in windowTitles(owner: owner) {
            let lower = title.lowercased()
            if lower.hasPrefix("meet") || lower.contains("meet.google.com") || title.range(of: #"\b[a-z]{3}-[a-z]{4}-[a-z]{3}\b"#,options: .regularExpression) != nil {
                let name = title.replacingOccurrences(of: #"^Meet\s*[-–:]\s*"#,with: "",options: .regularExpression)
                return ("Google Meet",name.isEmpty || name == title ? "Google Meet" : name)
            }
            if lower.contains("microsoft teams") || lower.contains("| teams") { return ("Teams",title) }
            if lower.contains("zoom") { return ("Zoom",title) }
            if lower.contains("whereby") || lower.contains("jitsi") { return ("Web-Meeting",title) }
        }
        return nil
    }
    static func windowTitle(owners: [String]) -> String? {
        owners.lazy.flatMap { windowTitles(owner: $0) }.first { !$0.isEmpty && !$0.hasPrefix("Zoom Workplace") }
    }
    static func windowTitles(owner: String) -> [String] {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { $0[kCGWindowName as String] as? String }.filter { !$0.isEmpty }
    }
    static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0,count: 1024)
        return proc_name(pid,&buffer,UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }
}
