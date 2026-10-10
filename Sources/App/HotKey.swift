import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon. Needs no Accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        install()
        let id = UInt32(handlers.count + 1)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_4147), id: id) // 'SNAG'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return false }
        handlers[id] = handler
        refs.append(ref)
        return true
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let fired = id.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(fired) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
