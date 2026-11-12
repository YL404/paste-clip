import AppKit

/// Polls the general pasteboard; macOS has no change notification for it.
final class PasteboardMonitor {
    // Markers used by password managers and similar apps (https://nspasteboard.org).
    private static let ignoredTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]
    /// Image flavors to try in order. A text flavor wins over any of them.
    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
        NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
    ]

    private let pasteboard = NSPasteboard.general
    private let onText: (String) -> Void
    private let onImage: (Data) -> Void
    private let onAccessDenied: () -> Void
    private var changeCount: Int
    private var timer: Timer?

    init(onText: @escaping (String) -> Void, onImage: @escaping (Data) -> Void,
         onAccessDenied: @escaping () -> Void) {
        self.onText = onText
        self.onImage = onImage
        self.onAccessDenied = onAccessDenied
        changeCount = pasteboard.changeCount
    }

    static var isAccessDenied: Bool {
        NSPasteboard.general.accessBehavior == .alwaysDeny
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
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

        guard !Self.isAccessDenied else {
            onAccessDenied()
            return
        }
        // Skip items marked as concealed or transient before reading their contents.
        guard let types = pasteboard.types, Self.ignoredTypes.isDisjoint(with: types) else { return }
        // A plain-text flavor takes priority, so copying an image together with its URL
        // still records the text, as before.
        if let text = pasteboard.string(forType: .string) {
            onText(text)
            return
        }
        for type in Self.imageTypes {
            guard let data = pasteboard.data(forType: type) else { continue }
            onImage(data)
            return
        }
        // Some apps declare a single image flavor under a less common UTI.
        for type in types where type.rawValue.hasPrefix("public.") || type.rawValue == "com.compuserve.gif" {
            guard let data = pasteboard.data(forType: type) else { continue }
            onImage(data)
            return
        }
    }
}
