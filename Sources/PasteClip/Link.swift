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

    /// Extracts the video ID from youtube.com and youtu.be links.
    static func youTubeVideoID(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        let candidate: String?
        if host == "youtu.be" {
            candidate = path.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if path.first == "watch" {
                candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "v" }?.value
            } else if path.count >= 2, ["shorts", "embed", "live", "v"].contains(path[0]) {
                candidate = path[1]
            } else {
                candidate = nil
            }
        } else {
            candidate = nil
        }
        guard let candidate, candidate.count == 11,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return candidate
    }

    static func youTubeThumbnailURL(videoID: String) -> URL? {
        // mqdefault is 320×180 (16:9) and exists for every video.
        URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")
    }

    /// Finds the Open Graph or Twitter card image declared in the page's `<meta>` tags.
    static func previewImageURL(inHTML html: String, baseURL: URL) -> URL? {
        let priority = ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"]
        var found: [String: String] = [:]
        for tag in html.matches(of: /<meta\b[^>]*>/.ignoresCase()) {
            var attributes: [String: String] = [:]
            for match in tag.output.matches(of: /([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/) {
                let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
                attributes[match.output.1.lowercased()] = String(value)
            }
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
                  priority.contains(key), found[key] == nil,
                  let content = attributes["content"], !content.isEmpty
            else { continue }
            found[key] = content
        }
        for key in priority {
            guard let content = found[key],
                  let url = URL(string: decodeEntities(content).trimmingCharacters(in: .whitespaces), relativeTo: baseURL)?
                      .absoluteURL,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
            return url
        }
        return nil
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
