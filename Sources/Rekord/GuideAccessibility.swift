import AppKit
import ApplicationServices
import RecorderCore

/// Reads the UI element under a click through the Accessibility API (`AXUIElementCopyElementAtPosition`).
/// This gives „Klicke auf ‚Neue Rechnung‘“ instead of „Klicke hier“, system-wide: native apps, browsers
/// (web content is exposed as AX elements once a client asks for it) and Electron apps (`AXManualAccessibility`).
/// No keyboard monitoring: typing is detected by comparing a text field's character count when focus leaves.
/// Password fields (`AXSecureTextField`) are never read.
final class GuideAccessibility: @unchecked Sendable {
    static var trusted: Bool { AXIsProcessTrusted() }
    /// Shows the system prompt for the Accessibility permission (only once per app identity).
    static func requestTrust() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }

    private let queue = DispatchQueue(label: "dev.sapunov.rekord.guide-ax",qos: .userInitiated)
    private let systemWide = AXUIElementCreateSystemWide()
    private var events: [GuideEvent] = []
    private var enabledApps = Set<pid_t>()
    /// Text field clicked last: its element, character count at the click and the event data to repeat.
    private var pendingField: (element: AXUIElement,characters: Int,event: GuideEvent)?
    /// Captured region in global screen points (origin top-left) and the recorded pixel size, to normalize positions.
    private var bounds = CGRect.zero
    private var dimensions = (1,1)
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() { AXUIElementSetMessagingTimeout(systemWide,0.3) }

    func begin(bounds: CGRect,dimensions: (Int,Int)) {
        queue.sync { self.bounds = bounds; self.dimensions = dimensions; events = []; pendingField = nil }
        // Ask browsers and Electron apps that are already open to expose their web content.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular { enableWebAccessibility(app.processIdentifier) }
    }
    /// Records a click at `location` (global points, origin top-left) at recording time `time`.
    func click(at location: CGPoint,time: Double,right: Bool) {
        queue.async { self.capture(location: location,time: time,right: right) }
    }
    /// Finishes the pending text field and returns all events.
    func finish() -> GuideCapture {
        queue.sync {
            closePendingField(time: nil)
            return GuideCapture(events: events.sorted { $0.time < $1.time },accessibility: Self.trusted)
        }
    }

    private func normalized(_ p: CGPoint) -> Point {
        let fit = min(Double(dimensions.0)/max(1,bounds.width),Double(dimensions.1)/max(1,bounds.height))
        let ox = (Double(dimensions.0)-bounds.width*fit)/2, oy = (Double(dimensions.1)-bounds.height*fit)/2
        return Point(((p.x-bounds.minX)*fit+ox)/Double(dimensions.0),((p.y-bounds.minY)*fit+oy)/Double(dimensions.1)).clamped()
    }
    private func normalized(_ r: CGRect) -> GuideRect {
        let a = normalized(r.origin), b = normalized(CGPoint(x: r.maxX,y: r.maxY))
        return GuideRect(x: a.x,y: a.y,width: b.x-a.x,height: b.y-a.y)
    }

    private func capture(location: CGPoint,time: Double,right: Bool) {
        closePendingField(time: time)
        var event = GuideEvent(time: time,kind: right ? .rightClick : .click,position: normalized(location))
        guard Self.trusted else { events.append(event); return }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide,Float(location.x),Float(location.y),&hit) == .success, var element = hit else { events.append(event); return }
        var pid: pid_t = 0; AXUIElementGetPid(element,&pid)
        if pid == ownPID { return }   // Rekord's own controller
        if !enabledApps.contains(pid) {
            enableWebAccessibility(pid)
            // A browser builds its web tree only after the first request; ask again once.
            if role(of: element) == "WebArea" || role(of: element) == "Group" {
                usleep(150_000)
                var again: AXUIElement?
                if AXUIElementCopyElementAtPosition(systemWide,Float(location.x),Float(location.y),&again) == .success, let again { element = again }
            }
        }
        element = actionableAncestor(of: element)
        let app = NSRunningApplication(processIdentifier: pid)
        event.appName = app?.localizedName; event.bundleID = app?.bundleIdentifier
        event.element = describe(element)
        let window: AXUIElement? = attribute(element,kAXWindowAttribute)
        event.windowTitle = window.flatMap { string($0,kAXTitleAttribute) }.flatMap(GuideElementText.clean)
        event.url = SensitiveText.strippedURL(pageURL(from: element))
        if let title = event.windowTitle { event.windowTitle = SensitiveText.masked(title) }
        events.append(event)
        if event.element?.editable == true, event.element?.secure == false {
            pendingField = (element,characterCount(element),event)
        } else if event.element?.secure == true {
            pendingField = nil
        }
    }
    /// After leaving a text field: if its length changed, a `typed` event (no text) is added.
    private func closePendingField(time: Double?) {
        guard let pending = pendingField else { return }
        pendingField = nil
        let now = characterCount(pending.element)
        guard now != pending.characters else { return }
        var typed = pending.event
        typed.kind = .typed; typed.characters = now
        typed.time = time.map { max(pending.event.time+0.01,$0-0.01) } ?? pending.event.time+0.01
        events.append(typed)
    }

    // MARK: AX helpers

    private func enableWebAccessibility(_ pid: pid_t) {
        guard pid > 0, pid != ownPID, !enabledApps.contains(pid) else { return }
        enabledApps.insert(pid)
        AccessibilityReader.enableWebAccessibility(pid)
    }

    private func attribute<T>(_ element: AXUIElement,_ name: String) -> T? { AccessibilityReader.attribute(element,name) }
    private func string(_ element: AXUIElement,_ name: String) -> String? { AccessibilityReader.string(element,name) }
    private func role(of element: AXUIElement) -> String { AccessibilityReader.role(of: element) }
    private func characterCount(_ element: AXUIElement) -> Int { AccessibilityReader.characterCount(element) }
    private func actionableAncestor(of element: AXUIElement) -> AXUIElement { AccessibilityReader.actionableAncestor(of: element) }
    private func describe(_ element: AXUIElement) -> GuideElement { AccessibilityReader.describe(element,normalize: normalized) }
    private func pageURL(from element: AXUIElement) -> String? { AccessibilityReader.pageURL(from: element) }

}

enum GuideElementText {
    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.replacingOccurrences(of: #"\s+"#,with: " ",options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(160))
    }
}
