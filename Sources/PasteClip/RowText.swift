import Foundation

/// Text of a list row and the parts to style. Offsets and ranges are in UTF-16 units of `string`.
nonisolated struct RowText: Equatable {
    var string: String
    /// Start of the trailing part drawn in a secondary color, such as a link's path.
    var dimmedFrom: Int?

    /// A link without its scheme, with everything after the host dimmed.
    static func link(_ text: String) -> RowText {
        guard let scheme = text.range(of: "://") else { return RowText(string: text) }
        let string = String(text[scheme.upperBound...])
        let hostEnd = string.firstIndex { "/?#".contains($0) }
        return RowText(string: string, dimmedFrom: hostEnd.map { string.utf16.distance(from: string.startIndex, to: $0) })
    }
}
