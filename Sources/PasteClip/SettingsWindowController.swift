import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Settings window with a shortcut recorder and the launch-at-login switch. The window is
/// created on demand and released when closed, so it costs no memory while unused.
final class SettingsWindowController: NSObject {
    private let hotKey: HotKey
    private var window: NSWindow?
    private var recordButton: NSButton?
    private var messageLabel: NSTextField?
    private var launchAtLoginCheckbox: NSButton?
    private var keyMonitor: Any?

    init(hotKey: HotKey) {
        self.hotKey = hotKey
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // The user may have changed login items in System Settings meanwhile.
        launchAtLoginCheckbox?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let label = NSTextField(labelWithString: "唤出快捷键：")
        let button = NSButton(title: Shortcut.load().displayString, target: self, action: #selector(startRecording))
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let message = NSTextField(labelWithString: "")
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let checkbox = NSButton(checkboxWithTitle: "开机时自动启动", target: self, action: #selector(toggleLaunchAtLogin))

        let row = NSStackView(views: [label, button])
        let stack = NSStackView(views: [row, message, checkbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 130),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "PasteClip 设置"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        recordButton = button
        messageLabel = message
        launchAtLoginCheckbox = checkbox
        return window
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if launchAtLoginCheckbox?.state == .on {
                try service.register()
            } else {
                try service.unregister()
            }
            messageLabel?.stringValue = ""
        } catch {
            messageLabel?.stringValue = "无法修改开机启动：\(error.localizedDescription)"
        }
        if service.status == .requiresApproval {
            messageLabel?.stringValue = "请在系统设置的“登录项”中允许 PasteClip"
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLoginCheckbox?.state = service.status == .enabled ? .on : .off
    }

    @objc private func startRecording() {
        guard keyMonitor == nil else { return }
        // Release the current shortcut so pressing it again can be recorded.
        hotKey.unregister()
        recordButton?.title = "请按下快捷键…"
        messageLabel?.stringValue = "需包含 ⌘、⌃ 或 ⌥；按 Esc 取消"
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.record(event) ? nil : event
        }
    }

    /// Returns true when the event was consumed by the recorder.
    private func record(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.isEmpty, Int(event.keyCode) == kVK_Escape {
            finishRecording(message: "")
            return true
        }
        guard !flags.isDisjoint(with: [.command, .control, .option]) else {
            NSSound.beep()
            return true
        }
        let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(flags), key: Self.keyName(event))
        if hotKey.register(shortcut) {
            shortcut.save()
            finishRecording(message: "")
        } else {
            finishRecording(message: "\(shortcut.displayString) 无法注册，可能已被其他 app 占用")
        }
        return true
    }

    private func finishRecording(message: String) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        let current = Shortcut.load()
        // Restores the saved shortcut after a cancel or failure, or re-registers the new one.
        if !hotKey.register(current) {
            log.error("Failed to register the global shortcut")
        }
        recordButton?.title = current.displayString
        messageLabel?.stringValue = message
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        return UInt32(modifiers)
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        if let name = specialKeyNames[Int(event.keyCode)] { return name }
        // Without modifiers applied, ⇧⌘1 shows as "1" instead of "!".
        return event.characters(byApplyingModifiers: [])?.uppercased() ?? "?"
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if keyMonitor != nil {
            finishRecording(message: "")
        }
        window = nil
        recordButton = nil
        messageLabel = nil
        launchAtLoginCheckbox = nil
    }
}
