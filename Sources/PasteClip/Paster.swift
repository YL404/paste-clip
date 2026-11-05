import AppKit
import Carbon.HIToolbox

enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Puts `text` on the pasteboard and sends ⌘V to the frontmost app.
    /// Without Accessibility permission the text stays on the pasteboard for a manual paste.
    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard isTrusted else {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        Task { @concurrent in
            // Give the window server a moment to return key focus to the previous app
            // after the panel closes; otherwise the keystroke can land nowhere.
            try? await Task.sleep(for: .milliseconds(50))
            let source = CGEventSource(stateID: .combinedSessionState)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
