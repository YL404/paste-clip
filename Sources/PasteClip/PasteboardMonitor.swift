import AppKit

/// Polls the general pasteboard; macOS has no change notification for it.
final class PasteboardMonitor {
    // Markers used by password managers and similar apps (https://nspasteboard.org).
    private static let ignoredTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    private let pasteboard = NSPasteboard.general
    private let onText: (String) -> Void
    private let onAccessDenied: () -> Void
    private var changeCount: Int
    private var timer: Timer?

    init(onText: @escaping (String) -> Void, onAccessDenied: @escaping () -> Void) {
        self.onText = onText
        self.onAccessDenied = onAccessDenied
        changeCount = pasteboard.changeCount
    }

    func start() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop below.
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != changeCount else { return }
        changeCount = count

        guard pasteboard.accessBehavior != .alwaysDeny else {
            onAccessDenied()
            return
        }
        // Skip items marked as concealed or transient before reading their contents.
        guard let types = pasteboard.types, Self.ignoredTypes.isDisjoint(with: types),
              let text = pasteboard.string(forType: .string)
        else { return }
        onText(text)
    }
}
