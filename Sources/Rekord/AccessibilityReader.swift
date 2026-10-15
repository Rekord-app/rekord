import AppKit
import ApplicationServices
import RecorderCore

enum AccessibilityReader {
    static func enableWebAccessibility(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.3)
        AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue)
        if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           ["com.google.Chrome","com.google.Chrome.canary","com.brave.Browser","com.microsoft.edgemac","company.thebrowser.Browser","com.vivaldi.Vivaldi","com.operasoftware.Opera"].contains(bundle) {
            AXUIElementSetAttributeValue(app,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue)
        }
    }
    /// All editable rectangles, without reading their values. Incomplete trees fail closed for screenshots.
    static func editableFrames(in root: AXUIElement) -> [CGRect]? {
        var frames: [CGRect] = [], remaining = 600
        func visit(_ node: AXUIElement,depth: Int) -> Bool {
            remaining -= 1; guard remaining >= 0,depth < 30 else { return false }
            let r = role(of: node), sub = string(node,kAXSubroleAttribute) ?? ""
            if GuideElement.editableRoles.contains(r) || sub.contains("SecureTextField") {
                guard let box = frame(of: node) else { return false }; frames.append(box); return true
            }
            let children: [AXUIElement] = attribute(node,kAXChildrenAttribute) ?? []
            return children.allSatisfy { visit($0,depth: depth+1) }
        }
        return visit(root,depth: 0) ? frames : nil
    }
    static func focusedApplication(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app,0.3); return app
    }
    static func focusedWindow(of app: AXUIElement) -> AXUIElement? { attribute(app,kAXFocusedWindowAttribute) }
    static func focusedElement(of app: AXUIElement) -> AXUIElement? { attribute(app,kAXFocusedUIElementAttribute) }
    static func windowSubrole(_ window: AXUIElement) -> String { string(window,kAXSubroleAttribute) ?? "" }
    static func attribute<T>(_ element: AXUIElement,_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success, let value else { return nil }
        return value as? T
    }
    static func string(_ element: AXUIElement,_ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success, let value else { return nil }
        if let s = value as? String { return s }
        if let a = value as? NSAttributedString { return a.string }
        if let n = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }
    static func role(of element: AXUIElement) -> String { (string(element,kAXRoleAttribute) ?? "AXUnknown").replacingOccurrences(of: "AX",with: "",options: .anchored) }
    static func characterCount(_ element: AXUIElement) -> Int {
        if let n: NSNumber = attribute(element,kAXNumberOfCharactersAttribute) { return n.intValue }
        return string(element,kAXValueAttribute)?.count ?? 0
    }
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let p: AXValue = attribute(element,kAXPositionAttribute), let s: AXValue = attribute(element,kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p,.cgPoint,&point), AXValueGetValue(s,.cgSize,&size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point,size: size)
    }
    /// Static text, images and unlabeled groups inside a button or link: use the control instead.
    static func actionableAncestor(of element: AXUIElement) -> AXUIElement {
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
    static func describe(_ element: AXUIElement, normalize: (CGRect) -> GuideRect = { GuideRect(x: $0.minX,y: $0.minY,width: $0.width,height: $0.height) }) -> GuideElement {
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
                                  frame: frame(of: element).map(normalize),secure: secure)
        return result
    }
    /// First visible text below an element (link and button labels in web pages are child text nodes).
    static func firstText(in element: AXUIElement,depth: Int) -> String? {
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
    static func pageURL(from element: AXUIElement) -> String? {
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
