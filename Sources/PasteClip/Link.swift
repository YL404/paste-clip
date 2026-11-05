import Foundation

nonisolated enum Link {
    /// Returns a URL when the whole text is a single http(s) link.
    static func webURL(in text: String) -> URL? {
        guard text.utf8.count <= 2048,
              !text.contains(where: \.isWhitespace),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }
}
