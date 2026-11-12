import AppKit

/// Text view that hands keyboard focus back once a click or drag selection ends,
/// so typing keeps going to the search field.
private final class PreviewTextView: NSTextView {
    var onMouseUp: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // NSTextView tracks the drag inside mouseDown and returns on mouse up.
        super.mouseDown(with: event)
        onMouseUp?()
    }
}

/// Glass card that shows the full text of the selected clip, up to `characterLimit` characters.
final class PreviewCard: NSGlassEffectView {
    static let width: CGFloat = 360
    static let characterLimit = 20_000
    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let textInset = NSSize(width: 12, height: 10)
    private static let footerHeight: CGFloat = 28
    private static let matchColor = NSColor.systemYellow.withAlphaComponent(0.4)

    private let textView = PreviewTextView()
    private let footer = NSTextField(labelWithString: "")

    var onMouseUp: (() -> Void)? {
        get { textView.onMouseUp }
        set { textView.onMouseUp = newValue }
    }

    init() {
        super.init(frame: .zero)
        cornerRadius = 16

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.textContainerInset = Self.textInset
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false

        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.lineBreakMode = .byTruncatingTail

        let content = NSView()
        for view in [scrollView, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.footerHeight),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            footer.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.footerHeight / 2),
        ])
        contentView = content
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `text`, whose full length is `length` characters, and returns the card height
    /// that fits it, capped at `maxHeight`.
    func show(_ text: String, length: Int, usedAt: Date, matching term: String, maxHeight: CGFloat) -> CGFloat {
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: Self.font, .foregroundColor: NSColor.labelColor,
        ])
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            var start = text.startIndex
            while let range = text.range(of: trimmed, options: .caseInsensitive, range: start..<text.endIndex) {
                attributed.addAttribute(.backgroundColor, value: Self.matchColor, range: NSRange(range, in: text))
                start = range.upperBound
            }
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.scroll(.zero)
        let size = length > Self.characterLimit
            ? "共 \(length.formatted()) 字，仅显示前 \(Self.characterLimit.formatted()) 字"
            : "共 \(length.formatted()) 字"
        // Relative ("3分钟前", "昨天") keeps the line short enough for the card width.
        footer.stringValue = "复制于 \(usedAt.formatted(.relative(presentation: .named))) · \(size)"

        let padding = textView.textContainer?.lineFragmentPadding ?? 0
        let textWidth = Self.width - 2 * (Self.textInset.width + padding)
        let textHeight = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.font]
        ).height
        return min(maxHeight, textHeight.rounded(.up) + 2 * Self.textInset.height + 4 + Self.footerHeight)
    }

    /// Releases the shown text.
    func clear() {
        textView.textStorage?.setAttributedString(NSAttributedString())
    }

    /// Copies the selected preview text. Returns false when nothing is selected.
    func copySelection() -> Bool {
        guard !isHidden, textView.selectedRange().length > 0 else { return false }
        textView.copy(nil)
        return true
    }
}
