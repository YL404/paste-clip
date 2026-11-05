import Carbon.HIToolbox
import Foundation

struct Shortcut: Codable, Equatable {
    /// Virtual key code (`kVK_*`).
    var keyCode: UInt32
    /// Carbon modifier flags (`cmdKey`, `shiftKey`, ...).
    var modifiers: UInt32
    /// Display text for the key itself, captured when the shortcut was recorded.
    var key: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), key: "V")

    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }

    private static let defaultsKey = "shortcut"

    static func load() -> Shortcut {
        UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// A single global hot key. Carbon's `RegisterEventHotKey` needs no Accessibility permission.
final class HotKey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // HotKey lives for the whole process, so the handler is never removed.
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            // The application event target dispatches on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// Replaces the current hot key. Returns false when the system rejects the combination,
    /// for example because another app already registered it.
    func register(_ shortcut: Shortcut) -> Bool {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        let id = EventHotKeyID(signature: OSType(0x5043_4C50), id: 1) // "PCLP"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref
        return status == noErr
    }
}
