import AppKit

/// Small red dot in the menu bar while a meeting records, so the floating controller can stay hidden.
@MainActor final class MeetingMenuBar: NSObject {
    private weak var store: MeetingStore?
    private var item: NSStatusItem?
    init(store: MeetingStore) { self.store = store }
    func update() {
        guard let store,store.phase == .recording else { if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil; return }
        if item == nil { item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        item?.button?.title = "●"
        item?.button?.contentTintColor = .systemRed
        item?.button?.toolTip = "Rekord nimmt dieses Meeting auf"
        let menu = NSMenu()
        let header = NSMenuItem(title: "Meeting wird aufgenommen\(store.callApp.map { " · \($0)" } ?? "")",action: nil,keyEquivalent: ""); header.isEnabled = false
        menu.addItem(header); menu.addItem(.separator())
        for (title,action) in [("Controller zeigen",#selector(showController)),("Aufnahme stoppen",#selector(stop)),("Verwerfen",#selector(discard))] {
            let entry = NSMenuItem(title: title,action: action,keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        item?.menu = menu
    }
    @objc private func showController() { store?.showControllerPanel() }
    @objc private func stop() { store?.stop() }
    @objc private func discard() { store?.discard() }
}
