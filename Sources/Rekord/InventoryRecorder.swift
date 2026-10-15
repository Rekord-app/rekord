import AppKit
import ApplicationServices
import ScreenCaptureKit
import RecorderCore

/// Serial worker. Only the front window is captured: background/private windows on the display never enter OCR.
actor InventoryRecorder {
    private var pending: InventorySample?
    private var lastImage = Date.distantPast
    private var lastContext = ""
    private var previousTick: Date?
    let root: URL
    init(root: URL) { self.root = root }
    static var locked: Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }
    static var idle: Bool { CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType: .null) > 120 }
    func flush() throws {
        if let pending { try InventoryFile.append(pending,to: InventoryFolder.directory(pending.start,root: root)); self.pending = nil }
    }
    func accept(_ sample: InventorySample) throws {
        let clean = sample.sanitized()
        if let previous = pending, InventoryFolder.day(previous.start) == InventoryFolder.day(clean.start), previous.sameContext(as: clean), clean.start.timeIntervalSince(previous.end) <= 5,
           clean.end.timeIntervalSince(previous.start) < 60, clean.snapshot == nil, clean.text.isEmpty || previous.text == clean.text {
            pending?.end = clean.end
        } else { try flush(); pending = clean }
    }
    func tick(paused reason: String?,exclusions: [String],fixtureWindow: CGWindowID? = nil) async throws -> InventorySample {
        let now = Date(), start = max(previousTick ?? now,now.addingTimeInterval(-5)); previousTick = now
        var pause = reason
        if Self.locked { pause = "locked" } else if Self.idle { pause = pause ?? "idle" }
        if let pause { let s = InventorySample(start: start,end: now,paused: pause); try accept(s); return s }
        let app = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        guard let app else { let s = InventorySample(start: start,end: now,paused: "idle"); try accept(s); return s }
        let bundle = app.bundleIdentifier ?? "", pid = app.processIdentifier
        if let reason = InventoryExclusions.reason(bundleID: bundle,windowTitle: "",additional: exclusions) {
            let s = InventorySample(start: start,end: now,paused: reason); try accept(s); return s
        }
        var editableFrames: [CGRect]?
        var title = "", subrole = "", label = "", role = "", url: String?, windowFrame: CGRect?
        let trusted = GuideAccessibility.trusted
        if trusted {
            AccessibilityReader.enableWebAccessibility(pid)
            let ax = AccessibilityReader.focusedApplication(pid)
            if let window = AccessibilityReader.focusedWindow(of: ax) {
                title = AccessibilityReader.string(window,kAXTitleAttribute) ?? ""; subrole = AccessibilityReader.windowSubrole(window); windowFrame = AccessibilityReader.frame(of: window); editableFrames = AccessibilityReader.editableFrames(in: window)
            }
            if let element = AccessibilityReader.focusedElement(of: ax) {
                let description = AccessibilityReader.describe(element)
                role = description.role; label = description.secure ? "" : description.label ?? ""
                url = AccessibilityReader.pageURL(from: element)
                // Editable values must not sneak in through OCR; pause while a field has focus.
                if description.editable { let s = InventorySample(start: start,end: now,paused: "editable"); try accept(s); return s }
            }
        }
        if fixtureWindow != nil, !title.contains("Testfirma") {
            let s = InventorySample(start: start,end: now,paused: "excluded"); try accept(s); return s
        }
        if let reason = InventoryExclusions.reason(bundleID: bundle,windowTitle: title + " " + (url ?? ""),subrole: subrole,additional: exclusions) {
            let s = InventorySample(start: start,end: now,paused: reason); try accept(s); return s
        }
        let browser = ["safari","chrome","browser","firefox","edgemac","vivaldi","opera"].contains { bundle.lowercased().contains($0) }
        // No reliable private-window or field check without AX: app metadata only.
        var s = InventorySample(start: start,end: now,appName: app.localizedName ?? bundle,bundleID: bundle,windowTitle: title,url: url,focusedRole: role,focusedLabel: label)
        let context = [bundle,title,url ?? ""].joined(separator: "|")
        if trusted, editableFrames != nil, (!browser || !title.isEmpty), CGPreflightScreenCaptureAccess(), context != lastContext || now.timeIntervalSince(lastImage) >= 30 {
            if #available(macOS 14.0, *) {
                let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly: true)
                let window = content.windows.first { w in
                    w.owningApplication?.processID == pid && w.windowLayer == 0 && w.frame.width > 100 && w.frame.height > 100 &&
                    (fixtureWindow.map { w.windowID == $0 } ?? (windowFrame.map { abs(w.frame.minX-$0.minX) < 4 && abs(w.frame.minY-$0.minY) < 4 } ?? false))
                }
                if let window {
                    let filter = SCContentFilter(desktopIndependentWindow: window), config = SCStreamConfiguration()
                    let scale = min(1,1280 / max(window.frame.width,window.frame.height))
                    config.width = max(2,Int(window.frame.width*scale)); config.height = max(2,Int(window.frame.height*scale)); config.showsCursor = false
                    let rawImage = try await SCScreenshotManager.captureImage(contentFilter: filter,configuration: config)
                    // Re-check focus, lock and exclusion after the asynchronous capture. Discard a changed context.
                    let currentPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
                    guard currentPID == pid, !Self.locked else { let pause = InventorySample(start: start,end: now,paused: "private"); try accept(pause); return pause }
                    let focused = AccessibilityReader.focusedWindow(of: AccessibilityReader.focusedApplication(pid))
                    guard let focused, AccessibilityReader.string(focused,kAXTitleAttribute) == title,
                          let afterFields = AccessibilityReader.editableFrames(in: focused) else {
                        let pause = InventorySample(start: start,end: now,paused: "private"); try accept(pause); return pause
                    }
                    let fields = (editableFrames ?? []) + afterFields
                    let fieldMasks = fields.map { rect in GuideRedaction(rect: GuideRect(x: (rect.minX-window.frame.minX)/window.frame.width,y: (rect.minY-window.frame.minY)/window.frame.height,width: rect.width/window.frame.width,height: rect.height/window.frame.height).padded(0.05),reason: "editable") }
                    guard let image = GuideImages.render(rawImage,click: nil,redactions: fieldMasks,maxWidth: 1280) else { throw GuideImageError.write }
                    let lines = try TextRecognition.recognizeText(in: image,fast: true)
                    if InventoryExclusions.reason(bundleID: bundle,windowTitle: lines.map(\.text).joined(separator: " ")) == nil {
                        s.text = String(SensitiveText.masked(lines.map(\.text).joined(separator: "\n")).prefix(1500))
                        let redactions = try GuideImages.sensitiveRegions(in: image)
                        if let redacted = GuideImages.render(image,click: nil,redactions: redactions,maxWidth: 1280) {
                            let relative = "snapshots/\(Int64(now.timeIntervalSince1970*1000)).jpg"
                            let file = InventoryFolder.directory(now,root: root).appendingPathComponent(relative)
                            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),withIntermediateDirectories: true)
                            try GuideImages.writeJPEG(redacted,to: file,quality: 0.5); s.snapshot = relative
                        }
                    } else { s = InventorySample(start: start,end: now,paused: "excluded") }
                    lastImage = now; lastContext = context
                }
            }
        }
        try accept(s); return s
    }
}

@MainActor enum InventoryPresentation {
    static var isFullscreen: Bool {
        guard GuideAccessibility.trusted,let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window = AccessibilityReader.focusedWindow(of: AccessibilityReader.focusedApplication(pid)) else { return true }
        let full: NSNumber? = AccessibilityReader.attribute(window,"AXFullScreen")
        return full?.boolValue ?? false
    }
}
