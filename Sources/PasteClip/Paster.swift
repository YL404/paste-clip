import AppKit
import Carbon.HIToolbox

enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Puts `content` on the pasteboard and sends ⌘V to the frontmost app.
    /// Without Accessibility permission the content stays on the pasteboard for a manual paste.
    static func paste(_ content: ClipContent) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch content {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .image(let data, _):
            // Some apps only read TIFF; write both flavors from the same PNG data.
            pasteboard.setData(data, forType: .png)
            if let image = NSImage(data: data) {
                pasteboard.setData(image.tiffRepresentation, forType: .tiff)
            }
        }

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
