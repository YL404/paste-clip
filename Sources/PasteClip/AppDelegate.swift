import AppKit
import os

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let log = Logger(subsystem: "com.liam.PasteClip", category: "app")
    private var statusItem: NSStatusItem?
    private var store: ClipStore?
    private var monitor: PasteboardMonitor?

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
            try store.purgeExpiredTrash()
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }
        self.store = store

        let monitor = PasteboardMonitor(
            onText: { [weak self] text in self?.record(text) },
            onAccessDenied: { [weak self] in self?.updateStatusIcon() }
        )
        monitor.start()
        self.monitor = monitor

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    // MARK: - Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateStatusIcon()
        menu.removeAllItems()
        if Self.pasteboardAccessDenied {
            menu.addItem(withTitle: "无法读取剪贴板：请在“隐私与安全性”中允许 PasteClip 访问…",
                         action: #selector(openPrivacySettings), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "退出 PasteClip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func updateStatusIcon() {
        let symbol = Self.pasteboardAccessDenied ? "exclamationmark.triangle" : "doc.on.clipboard"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PasteClip")
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - History

    private func record(_ text: String) {
        do {
            try store?.record(text)
        } catch {
            log.error("Failed to record clip: \(error, privacy: .public)")
        }
    }

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
