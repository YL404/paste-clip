import os

let log = Logger(subsystem: "com.liam.PasteClip", category: "app")

/// Runs `body` and logs a failure instead of throwing. Errors here come from SQLite or the
/// file system and never contain clip text.
@discardableResult
func logged<T>(_ action: String, _ body: () throws -> T) -> T? {
    do {
        return try body()
    } catch {
        log.error("\(action, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        return nil
    }
}
