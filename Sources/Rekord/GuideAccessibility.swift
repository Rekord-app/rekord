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
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.3)
        // Electron exposes its tree with AXManualAccessibility; Chromium and WebKit with AXEnhancedUserInterface.
        AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue)
        if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, Self.chromiumBrowsers.contains(bundle) {
            AXUIElementSetAttributeValue(app,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue)
        }
    }
    static let chromiumBrowsers: Set<String> = ["com.google.Chrome","com.google.Chrome.canary","com.brave.Browser","com.microsoft.edgemac","company.thebrowser.Browser","com.vivaldi.Vivaldi","com.operasoftware.Opera"]

    private func attribute<T>(_ element: AXUIElement,_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success, let value else { return nil }
        return value as? T
    }
    private func string(_ element: AXUIElement,_ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success, let value else { return nil }
        if let s = value as? String { return s }
        if let a = value as? NSAttributedString { return a.string }
        if let n = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }
    private func role(of element: AXUIElement) -> String { (string(element,kAXRoleAttribute) ?? "AXUnknown").replacingOccurrences(of: "AX",with: "",options: .anchored) }
    private func characterCount(_ element: AXUIElement) -> Int {
        if let n: NSNumber = attribute(element,kAXNumberOfCharactersAttribute) { return n.intValue }
        return string(element,kAXValueAttribute)?.count ?? 0
    }
    private func frame(of element: AXUIElement) -> CGRect? {
        guard let p: AXValue = attribute(element,kAXPositionAttribute), let s: AXValue = attribute(element,kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p,.cgPoint,&point), AXValueGetValue(s,.cgSize,&size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point,size: size)
    }
    /// Static text, images and unlabeled groups inside a button or link: use the control instead.
    private func actionableAncestor(of element: AXUIElement) -> AXUIElement {
        let r = role(of: element)
        guard ["StaticText","Image","Group","Unknown","Generic"].contains(r) else { return element }
        var current = element
        for _ in 0..<4 {
            guard let parent: AXUIElement = attribute(current,kAXParentAttribute) else { break }
            let pr = role(of: parent)
            if ["Button","Link","MenuItem","MenuButton","PopUpButton","CheckBox","RadioButton","Tab","Cell","Row","ListItem","MenuBarItem","DockItem","ComboBox","TextField"].contains(pr) { return parent }
            if ["Window","WebArea","ScrollArea","Application"].contains(pr) { break }
            current = parent
        }
        return element
    }
    private func describe(_ element: AXUIElement) -> GuideElement {
        let r = role(of: element)
        let subrole = string(element,kAXSubroleAttribute).map { $0.replacingOccurrences(of: "AX",with: "",options: .anchored) }
        let secure = r == "SecureTextField" || subrole == "SecureTextField" || (string(element,kAXRoleDescriptionAttribute)?.lowercased().contains("passwort") ?? false)
        let editable = GuideElement.editableRoles.contains(r) || secure
        var labelText: String?
        if let titleElement: AXUIElement = attribute(element,kAXTitleUIElementAttribute) { labelText = string(titleElement,kAXValueAttribute) ?? string(titleElement,kAXTitleAttribute) }
        if labelText == nil, !editable { labelText = firstText(in: element,depth: 3) }
        var value: String?
        if !editable { value = string(element,kAXValueAttribute).map(SensitiveText.masked) }
        let result = GuideElement(role: r,subrole: subrole,roleDescription: GuideElementText.clean(string(element,kAXRoleDescriptionAttribute)),
                                  title: GuideElementText.clean(string(element,kAXTitleAttribute)).map(SensitiveText.masked),
                                  description: GuideElementText.clean(string(element,kAXDescriptionAttribute)).map(SensitiveText.masked),
                                  value: GuideElementText.clean(value),
                                  placeholder: GuideElementText.clean(string(element,kAXPlaceholderValueAttribute)),
                                  help: GuideElementText.clean(string(element,kAXHelpAttribute)),
                                  labelText: GuideElementText.clean(labelText).map(SensitiveText.masked),
                                  frame: frame(of: element).map(normalized),secure: secure)
        return result
    }
    /// First visible text below an element (link and button labels in web pages are child text nodes).
    private func firstText(in element: AXUIElement,depth: Int) -> String? {
        guard depth > 0, let children: [AXUIElement] = attribute(element,kAXChildrenAttribute) else { return nil }
        for child in children.prefix(12) {
            let r = role(of: child)
            if r == "StaticText", let text = GuideElementText.clean(string(child,kAXValueAttribute)) { return text }
            if r == "Image", let text = GuideElementText.clean(string(child,kAXDescriptionAttribute)) { return text }
            if let text = firstText(in: child,depth: depth-1) { return text }
        }
        return nil
    }
    /// URL of the web page containing the element (Safari and Chromium expose `AXURL` on the web area).
    private func pageURL(from element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { break }
            if role(of: node) == "WebArea" {
                if let url: URL = attribute(node,kAXURLAttribute) { return url.absoluteString }
                if let s = string(node,kAXURLAttribute) { return s }
            }
            if role(of: node) == "Window" { break }
            current = attribute(node,kAXParentAttribute)
        }
        return nil
    }
}

enum GuideElementText {
    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.replacingOccurrences(of: #"\s+"#,with: " ",options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(160))
    }
}
