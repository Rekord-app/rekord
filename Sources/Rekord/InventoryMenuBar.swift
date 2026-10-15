import AppKit

@MainActor final class InventoryMenuBar: NSObject {
    private weak var store: InventoryStore?
    private var item: NSStatusItem?
    init(store: InventoryStore) { self.store = store }
    func update() {
        guard let store else { return }
        if store.phase == .off { if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil; return }
        if item == nil { item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        item?.button?.title = store.phase == .running && store.currentPause == nil ? "● Inventur" : "○ Inventur"
        item?.button?.contentTintColor = store.phase == .running && store.currentPause == nil ? .systemGreen : .secondaryLabelColor
        item?.button?.toolTip = "Arbeits-Inventur · jederzeit pausieren"
        let menu = NSMenu()
        for (title,action) in [("Inventur öffnen",#selector(open)),("Pause 15 Min.",#selector(pause15)),("Pause 1 Std.",#selector(pause60)),("Pause bis morgen",#selector(tomorrow)),("Fortsetzen",#selector(resume)),("Aktuelle App nie erfassen",#selector(exclude)),("Rückfrage jetzt",#selector(ask)),("Inventur stoppen",#selector(stop))] {
            let entry = NSMenuItem(title: title,action: action,keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        item?.menu = menu
    }
    @objc private func open() { store?.bringForward?() }
    @objc private func pause15() { store?.pause(minutes: 15) }
    @objc private func pause60() { store?.pause(minutes: 60) }
    @objc private func tomorrow() { store?.pauseUntilTomorrow() }
    @objc private func resume() { store?.resume() }
    @objc private func exclude() { store?.excludeCurrent() }
    @objc private func ask() { store?.ask(manual: true) }
    @objc private func stop() { store?.stop() }
}
