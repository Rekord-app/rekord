import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts that work while another app is in front, without Accessibility permission
/// (Carbon hot keys). Esc is only claimed while the recorder is open so other apps keep it otherwise.
@MainActor final class HotKeys {
    static let shared = HotKeys()
    enum Action: UInt32 { case escape = 1, stop, pause, meeting }
    private var registered: [Action: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    var perform: ((Action) -> Void)?

    func set(_ action: Action,enabled: Bool) {
        if enabled, registered[action] == nil {
            installHandler()
            let (code,modifiers): (Int,Int) = switch action {
            case .escape: (kVK_Escape,0)
            case .stop: (kVK_ANSI_2,cmdKey|shiftKey)
            case .pause: (kVK_ANSI_P,cmdKey|shiftKey)
            // Not ⌘⇧M: that is mute in Teams and the mini window in Zoom.
            case .meeting: (kVK_ANSI_M,controlKey|optionKey|cmdKey)
            }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x46_52_45_43),id: action.rawValue)   // 'FREC'
            if RegisterEventHotKey(UInt32(code),UInt32(modifiers),id,GetApplicationEventTarget(),0,&ref) == noErr, let ref { registered[action] = ref }
        } else if !enabled, let ref = registered.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }
    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),{ _,event,_ in
            var id = EventHotKeyID()
            GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
            if let action = HotKeys.Action(rawValue: id.id) { DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.perform?(action) } } }
            return noErr
        },1,&type,nil,nil)
    }
}
