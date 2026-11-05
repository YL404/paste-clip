import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var store: ClipStore?
    private var monitor: PasteboardMonitor?
    private var panel: PanelController?
    private var hotKey: HotKey?
    private var settings: SettingsWindowController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication holds its delegate weakly.
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store: ClipStore
        do {
            store = try ClipStore(url: Self.databaseURL())
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }
        self.store = store
        logged("Purge trash") { try store.purgeExpiredTrash() }
        let monitor = PasteboardMonitor(
            onText: { text in logged("Record clip") { try store.record(text) } },
            onAccessDenied: { [weak self] in self?.updateStatusIcon() }
        )
        monitor.start()
        self.monitor = monitor

        panel = PanelController(store: store) { [weak self] text in
            Paster.paste(text)
            self?.updateStatusIcon()
        }

        let hotKey = HotKey { [weak self] in self?.togglePanel() }
        if !hotKey.register(.load()) {
            log.error("Failed to register the global shortcut")
        }
        self.hotKey = hotKey
        settings = SettingsWindowController(hotKey: hotKey)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        panel.isVisible ? panel.hide() : panel.show()
    }

    // MARK: - Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateStatusIcon()
        menu.removeAllItems()
        if Self.pasteboardAccessDenied {
            menu.addItem(withTitle: "无法读取剪贴板：请在“隐私与安全性”中允许 PasteClip 访问…",
                         action: #selector(openPrivacySettings), keyEquivalent: "")
        }
        if !Paster.isTrusted {
            menu.addItem(withTitle: "自动粘贴需要辅助功能权限，前往开启…",
                         action: #selector(openAccessibilitySettings), keyEquivalent: "")
        }
        if menu.numberOfItems > 0 {
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "打开剪贴板历史（\(Shortcut.load().displayString)）",
                     action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "清空回收站…", action: #selector(emptyTrash), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 PasteClip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func updateStatusIcon() {
        let warning = Self.pasteboardAccessDenied || !Paster.isTrusted
        let symbol = warning ? "exclamationmark.triangle" : "doc.on.clipboard"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PasteClip")
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAccessibilitySettings() {
        Paster.openAccessibilitySettings()
    }

    @objc private func showSettings() {
        settings?.show()
    }

    @objc private func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "清空回收站？"
        alert.informativeText = "回收站中的记录将被永久删除，无法恢复。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, let store else { return }
        logged("Empty trash") { try store.emptyTrash() }
    }

    // MARK: - Helpers

    private static var pasteboardAccessDenied: Bool {
        NSPasteboard.general.accessBehavior == .alwaysDeny
    }

    private static func databaseURL() throws -> URL {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "PasteClip", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "clips.sqlite")
    }
}
