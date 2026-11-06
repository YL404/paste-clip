import Foundation

/// Text of a list row and the parts to style. Offsets and ranges are in UTF-16 units of `string`.
nonisolated struct RowText: Equatable {
    var string: String
    /// Start of the trailing part drawn in a secondary color, such as a link's path.
    var dimmedFrom: Int?
    /// Search matches, drawn in bold.
    var matches: [NSRange] = []

    /// A link without its scheme, with everything after the host dimmed.
    static func link(_ text: String) -> RowText {
        guard let scheme = text.range(of: "://") else { return RowText(string: text) }
        let string = String(text[scheme.upperBound...])
        let hostEnd = string.firstIndex { "/?#".contains($0) }
        return RowText(string: string, dimmedFrom: hostEnd.map { string.utf16.distance(from: string.startIndex, to: $0) })
    }

    /// Marks every case-insensitive occurrence of `term`.
    func highlighting(_ term: String) -> RowText {
        var result = self
        result.matches = []
        guard !term.isEmpty else { return result }
        var start = string.startIndex
        while let range = string.range(of: term, options: .caseInsensitive, range: start..<string.endIndex) {
            result.matches.append(NSRange(range, in: string))
            start = range.upperBound
        }
        return result
    }
}
