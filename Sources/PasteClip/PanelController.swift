import AppKit

/// Borderless panel that takes keyboard focus without activating the app,
/// so the previously active app stays frontmost and receives the paste.
private final class ClipPanel: NSPanel {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyEquivalentHandler?(event) == true || super.performKeyEquivalent(with: event)
    }

    // Caught here because the search field's editor, not the panel, is first responder.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            onModifiersChanged?(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }
        super.sendEvent(event)
    }
}

/// Transparent area around the glass card. A click there counts as a click outside the panel.
private final class MarginView: NSView {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }
}

/// Bottom strip of the list card. Dragging it sets the list height.
private final class ResizeHandle: NSView {
    /// Called with the mouse position in screen coordinates while dragging.
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?

    /// The hint label inside the strip must not take the drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // The app is never active, so the area must track in inactive windows too.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.frameResize(position: .bottom, directions: .all).set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        onDrag?(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}

/// Keeps the selection in accent color although the search field, not the table, has focus.
private final class ClipRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

private final class ClipCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ClipCell")
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let matchFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .bold)
    /// Space between the cell edge and the label's drawn text, measured from the laid-out cell.
    static let textPadding: CGFloat = 4
    static let spacing: CGFloat = 8
    static let accessoryFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// Gap between the row edge and the thumbnail.
    static let imageInset: CGFloat = 4
    /// Height of a row whose thumbnail sits right of the text.
    static let imageRowHeight = imageInset + ThumbnailCache.size.height + imageInset

    private let accessoryLabel = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        accessoryLabel.font = Self.accessoryFont
        accessoryLabel.textColor = .secondaryLabelColor

        let label = NSTextField(labelWithString: "")
        label.font = Self.font
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The text stretches, so the accessory sits at the trailing edge.
        label.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)

        thumbnailView.imageScaling = .scaleAxesIndependently
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 6
        thumbnailView.layer?.masksToBounds = true

        // Hidden views are detached from the stack, so rows without a thumbnail end with the text.
        let stack = NSStackView(views: [label, accessoryLabel, thumbnailView])
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = label
        NSLayoutConstraint.activate([
            thumbnailView.widthAnchor.constraint(equalToConstant: ThumbnailCache.size.width),
            thumbnailView.heightAnchor.constraint(equalToConstant: ThumbnailCache.size.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.imageInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.imageInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Width the accessory takes from the text, including the spacing before it.
    static func accessoryWidth(_ accessory: String) -> CGFloat {
        (accessory as NSString).size(withAttributes: [.font: accessoryFont]).width.rounded(.up) + spacing
    }

    static func attributedText(_ text: RowText, emphasized: Bool) -> NSAttributedString {
        let primary: NSColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(string: text.string, attributes: [
            .font: font, .foregroundColor: primary, .paragraphStyle: paragraph,
        ])
        if let dimmedFrom = text.dimmedFrom {
            let secondary = emphasized ? primary.withAlphaComponent(0.7) : .secondaryLabelColor
            result.addAttribute(.foregroundColor, value: secondary, range: NSRange(location: dimmedFrom, length: result.length - dimmedFrom))
        }
        for match in text.matches {
            result.addAttribute(.font, value: matchFont, range: match)
        }
        return result
    }

    private var text = RowText(string: "")

    /// `accessory` is short trailing text such as a shortcut hint; nil hides it.
    func configure(text: RowText, thumbnail: NSImage?, accessory: String?) {
        self.text = text
        textField?.attributedStringValue = Self.attributedText(text, emphasized: backgroundStyle == .emphasized)
        thumbnailView.image = thumbnail
        thumbnailView.isHidden = thumbnail == nil
        accessoryLabel.stringValue = accessory ?? ""
        accessoryLabel.isHidden = accessory == nil
    }

    /// The attributed text carries its own colors, and the accessory sits inside the stack view,
    /// so both follow the selection style explicitly.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            accessoryLabel.cell?.backgroundStyle = backgroundStyle
            textField?.attributedStringValue = Self.attributedText(text, emphasized: backgroundStyle == .emphasized)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class PanelController: NSObject {
    private static let width: CGFloat = 400
    /// Transparent space around the glass cards. Liquid Glass draws its shadow beyond its own
    /// frame, and a window edge right at a card would cut that shadow off as a visible ring.
    private static let margin: CGFloat = 32
    private static let previewGap: CGFloat = 8
    private static let maxPreviewHeight: CGFloat = 420
    private static let rowHeight: CGFloat = 32
    private static let defaultVisibleRows = 10
    private static let minVisibleRows = 3
    private static let listHeightKey = "PanelListHeight"
    private static let searchHeight: CGFloat = 44
    private static let footerHeight: CGFloat = 26
    private static let bannerHeight: CGFloat = 30
    /// Space the inset table style adds above and below the rows.
    private static let tableInsets: CGFloat = 10
    private static let pageSize = 50
    private static let maxCachedPages = 6

    private let store: ClipStore
    private let thumbnails: ThumbnailCache
    private let onPaste: (String) -> Void
    private let panel: ClipPanel
    private let listCard = NSGlassEffectView()
    private let previewCard = PreviewCard()
    private let searchField = NSTextField()
    private let trashButton = NSButton()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let resizeHandle = ResizeHandle()
    /// Missing permission notice under the search field, created the first time it is needed.
    private var banner: (view: NSView, label: NSTextField)?
    private var bannerAction: (() -> Void)?
    private var listTopConstraint: NSLayoutConstraint?

    private var list = ClipList.history
    private var query = ""
    private var rowCount = 0
    /// Rows are read from SQLite one page at a time; only a few pages stay in memory.
    private var pages: [Int: [Clip]] = [:]
    private var isReloading = false
    /// Height of the row area set by dragging the bottom strip; nil until the user drags it.
    /// The card shrinks below it when there are fewer rows.
    private var draggedListHeight: CGFloat?
    /// ⌘1–⌘9 hints show while ⌘ is held, but not while it is still held from the global shortcut.
    private var showsShortcutHints = false
    private var commandWasDown = false

    /// Card frames in screen coordinates. The window is sized around them.
    private var cardFrame = NSRect.zero
    private var previewFrame: NSRect?
    private var visibleFrame = NSRect.zero

    init(store: ClipStore, thumbnails: ThumbnailCache, onPaste: @escaping (String) -> Void) {
        self.store = store
        self.thumbnails = thumbnails
        self.onPaste = onPaste
        panel = ClipPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        let saved = UserDefaults.standard.double(forKey: Self.listHeightKey)
        draggedListHeight = saved > 0 ? saved : nil
        super.init()
        configurePanel()
        thumbnails.onLoad = { [weak self] link in self?.reloadRows(showing: link) }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        logged("Purge trash") { try store.purgeExpiredTrash() }
        list = .history
        query = ""
        searchField.stringValue = ""
        showsShortcutHints = false
        commandWasDown = NSEvent.modifierFlags.contains(.command)
        updateListAppearance()
        updateBanner()

        // The card's top-left corner goes to the mouse; reload() sizes it and keeps it on screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        visibleFrame = screen?.visibleFrame ?? NSRect(origin: .zero, size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        cardFrame = NSRect(x: mouse.x, y: mouse.y, width: Self.width, height: 0)
        reload()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func hide() {
        panel.orderOut(nil)
        thumbnails.reset()
        // Drop cached rows and preview text; the next show reads fresh data anyway.
        rowCount = 0
        pages = [:]
        tableView.reloadData()
        previewFrame = nil
        previewCard.clear()
    }

    // MARK: - Setup

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The glass draws its own shadow. A window shadow on top of it outlines the rectangular
        // window and is not recomputed when the panel resizes.
        panel.hasShadow = false
        panel.delegate = self
        panel.keyEquivalentHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        panel.onModifiersChanged = { [weak self] flags in self?.modifiersChanged(flags) }

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 16)
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        searchField.delegate = self

        trashButton.isBordered = false
        trashButton.refusesFirstResponder = true
        trashButton.imagePosition = .imageOnly
        trashButton.target = self
        trashButton.action = #selector(toggleList)
        trashButton.toolTip = "回收站（⌘T）"

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(listScrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.addSubview(hintLabel)
        resizeHandle.toolTip = "拖动调整高度"
        resizeHandle.onDrag = { [weak self] mouse in self?.resizeList(bottom: mouse.y) }
        resizeHandle.onDragEnd = { [weak self] in self?.finishResizing() }

        let content = NSView()
        for view in [searchField, trashButton, scrollView, emptyLabel, resizeHandle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let listTop = scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.searchHeight)
        listTopConstraint = listTop
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.searchHeight / 2),
            trashButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            trashButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            trashButton.widthAnchor.constraint(equalToConstant: 20),
            listTop,
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.footerHeight),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: resizeHandle.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: resizeHandle.trailingAnchor, constant: -16),
            hintLabel.centerYAnchor.constraint(equalTo: resizeHandle.centerYAnchor),
            resizeHandle.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            resizeHandle.heightAnchor.constraint(equalToConstant: Self.footerHeight),
        ])

        listCard.cornerRadius = 16
        listCard.contentView = content

        previewCard.isHidden = true
        previewCard.onMouseUp = { [weak self] in self?.focusSearchField() }

        let container = MarginView()
        container.onMouseDown = { [weak self] in self?.hide() }
        container.addSubview(listCard)
        container.addSubview(previewCard)
        panel.contentView = container
    }

    // MARK: - Layout

    /// Sizes the window around the cards and places them inside it.
    private func layoutWindow() {
        let cards = previewFrame.map(cardFrame.union) ?? cardFrame
        let frame = cards.insetBy(dx: -Self.margin, dy: -Self.margin)
        panel.setFrame(frame, display: panel.isVisible)
        listCard.frame = cardFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        if let previewFrame {
            previewCard.frame = previewFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        }
        previewCard.isHidden = previewFrame == nil
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    /// Shows the preview card next to the list when the selected clip doesn't fit its row.
    private func updatePreview() {
        let row = tableView.selectedRow
        guard let clip = clip(at: row), isTruncated(clip, row: row),
              let loaded = logged("Load preview", { try store.excerpt(of: clip.id, limit: PreviewCard.characterLimit) }),
              let excerpt = loaded
        else {
            if previewFrame != nil {
                previewFrame = nil
                previewCard.clear()
                layoutWindow()
            }
            return
        }
        let height = previewCard.show(excerpt.text, length: excerpt.length, usedAt: excerpt.usedAt, maxHeight: Self.maxPreviewHeight)
        previewFrame = previewFrame(forRow: row, height: height)
        layoutWindow()
    }

    /// Frame of the preview card beside the row, clamped to the screen.
    private func previewFrame(forRow row: Int, height: CGFloat) -> NSRect? {
        guard row >= 0, row < rowCount else { return nil }
        let rowInWindow = tableView.convert(tableView.rect(ofRow: row), to: nil)
        let rowOnScreen = panel.convertToScreen(rowInWindow)
        // Right of the list, or left when the screen has no room on the right.
        var frame = NSRect(x: cardFrame.maxX + Self.previewGap, y: rowOnScreen.maxY - height,
                           width: PreviewCard.width, height: height)
        if frame.maxX > visibleFrame.maxX {
            frame.origin.x = cardFrame.minX - Self.previewGap - frame.width
        }
        frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        return frame
    }

    /// Keeps the card beside its row when the list scrolls under it.
    @objc private func listScrolled() {
        guard let shown = previewFrame,
              let moved = previewFrame(forRow: tableView.selectedRow, height: shown.height),
              moved != shown
        else { return }
        previewFrame = moved
        layoutWindow()
    }

    private func isTruncated(_ clip: Clip, row: Int) -> Bool {
        display(clip, row: row).isTruncated
    }

    /// The row's text, and whether it leaves out part of the clip.
    private func display(_ clip: Clip, row: Int) -> (text: RowText, isTruncated: Bool) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (clip.link == nil ? RowText(string: clip.preview) : .link(clip.preview)).highlighting(term)
        let width = textWidth(for: clip, row: row)
        let attributed = ClipCellView.attributedText(text, emphasized: false)
        // When the first match is cut off or not in the preview at all, show the text around it.
        if let excerpt = clip.matchExcerpt {
            let matchFits = text.matches.first.map {
                attributed.attributedSubstring(from: NSRange(location: 0, length: NSMaxRange($0))).size().width <= width
            } ?? false
            if !matchFits {
                return (RowText(string: excerpt).highlighting(term), true)
            }
        }
        return (text, attributed.size().width > width)
    }

    /// Width the row's text label gets.
    private func textWidth(for clip: Clip, row: Int) -> CGFloat {
        var width = tableView.frameOfCell(atColumn: 0, row: row).width - ClipCellView.textPadding
        if let link = clip.link, thumbnails.hasImage(for: link) {
            width -= ThumbnailCache.size.width + ClipCellView.spacing
        }
        if let accessory = accessory(for: row) {
            width -= ClipCellView.accessoryWidth(accessory)
        }
        return width
    }

    /// Trailing text of a row. History: the ⌘1–⌘9 hint while ⌘ is held; the hints mirror
    /// ⌘1–⌘9, which only work in the history. Trash: days until the clip is deleted for good.
    private func accessory(for row: Int) -> String? {
        switch list {
        case .history:
            return showsShortcutHints && row < 9 ? "⌘\(row + 1)" : nil
        case .trash:
            guard let deletedAt = clip(at: row)?.deletedAt else { return nil }
            return "\(ClipStore.trashDaysLeft(deletedAt: deletedAt)) 天后删除"
        }
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let commandDown = flags.contains(.command)
        let shows = commandDown && (showsShortcutHints || !commandWasDown)
        commandWasDown = commandDown
        guard shows != showsShortcutHints else { return }
        showsShortcutHints = shows
        guard list == .history else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.lowerBound..<visible.upperBound), columnIndexes: IndexSet(integer: 0))
        updatePreview()
    }

    /// Returns focus to the search field without selecting its text, so typing continues.
    private func focusSearchField() {
        panel.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectedRange = NSRange(location: (searchField.stringValue as NSString).length, length: 0)
    }

    // MARK: - Data

    private func reload(selecting row: Int = 0) {
        isReloading = true
        pages = [:]
        rowCount = logged("Count clips") { try store.count(in: list, matching: query) } ?? 0
        tableView.reloadData()
        if rowCount > 0 {
            select(min(row, rowCount - 1))
        }
        isReloading = false

        emptyLabel.isHidden = rowCount > 0
        emptyLabel.stringValue = !query.isEmpty ? "没有匹配的记录" : list == .history ? "暂无记录" : "回收站为空"
        updateCardFrame()
        updatePreview()
    }

    /// Card height outside the row area.
    private var chromeHeight: CGFloat {
        Self.searchHeight + (isBannerVisible ? Self.bannerHeight : 0) + Self.footerHeight
    }

    private var isBannerVisible: Bool { banner?.view.isHidden == false }

    /// Height of a row: rows that show a thumbnail right of the text are taller.
    private func rowHeight(at row: Int) -> CGFloat {
        guard let link = clip(at: row)?.link, thumbnails.hasImage(for: link) else { return Self.rowHeight }
        return ClipCellView.imageRowHeight
    }

    /// Height of a full compact list, the panel's default size. Thumbnail rows make it show fewer rows.
    private var defaultListHeight: CGFloat {
        CGFloat(Self.defaultVisibleRows) * (Self.rowHeight + tableView.intercellSpacing.height) + Self.tableInsets
    }

    private func listHeight(rows: Int, upTo limit: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        var height = Self.tableInsets
        for row in 0..<rows {
            height += rowHeight(at: row) + tableView.intercellSpacing.height
            if height >= limit { break }
        }
        return height
    }

    /// Fits the card to the rows, up to the dragged height, keeping its top edge in place
    /// and the whole card on screen.
    private func updateCardFrame() {
        let maxHeight = draggedListHeight ?? defaultListHeight
        let height = min(chromeHeight + min(listHeight(rows: max(rowCount, 1), upTo: maxHeight), maxHeight), visibleFrame.height)
        var card = NSRect(x: cardFrame.minX, y: cardFrame.maxY - height, width: Self.width, height: height)
        card.origin.x = min(max(card.minX, visibleFrame.minX), visibleFrame.maxX - card.width)
        card.origin.y = min(max(card.minY, visibleFrame.minY), visibleFrame.maxY - card.height)
        cardFrame = card
        layoutWindow()
    }

    /// Moves the card's bottom edge to the mouse while dragging the bottom strip.
    private func resizeList(bottom: CGFloat) {
        let top = cardFrame.maxY
        let height = min(max(top - bottom, chromeHeight + listHeight(rows: Self.minVisibleRows)), top - visibleFrame.minY)
        draggedListHeight = height - chromeHeight
        cardFrame = NSRect(x: cardFrame.minX, y: top - height, width: Self.width, height: height)
        layoutWindow()
    }

    /// Saves the dragged height and shrinks the card back when it is taller than its rows.
    private func finishResizing() {
        guard let draggedListHeight else { return }
        UserDefaults.standard.set(Double(draggedListHeight), forKey: Self.listHeightKey)
        updateCardFrame()
        updatePreview()
    }

    private func clip(at row: Int) -> Clip? {
        guard row >= 0, row < rowCount else { return nil }
        let page = row / Self.pageSize
        let clips: [Clip]
        if let cached = pages[page] {
            clips = cached
        } else {
            let offset = page * Self.pageSize
            clips = logged("Load clips") {
                try store.clips(in: list, matching: query, offset: offset, limit: Self.pageSize)
            } ?? []
            if pages.count >= Self.maxCachedPages,
               let farthest = pages.keys.max(by: { abs($0 - page) < abs($1 - page) }) {
                pages[farthest] = nil
            }
            pages[page] = clips
        }
        let index = row % Self.pageSize
        return index < clips.count ? clips[index] : nil
    }

    private func reloadRows(showing link: URL) {
        guard panel.isVisible else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        let rows = IndexSet((visible.lowerBound..<visible.upperBound).filter { clip(at: $0)?.link == link })
        guard !rows.isEmpty else { return }
        // The thumbnail makes the row taller, so its height and the card size change with it.
        tableView.noteHeightOfRows(withIndexesChanged: rows)
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        updateCardFrame()
        updatePreview()
    }

    private func updateListAppearance() {
        let inTrash = list == .trash
        trashButton.image = NSImage(systemSymbolName: inTrash ? "trash.fill" : "trash", accessibilityDescription: "回收站")
        trashButton.contentTintColor = inTrash ? .controlAccentColor : .secondaryLabelColor
        searchField.placeholderString = inTrash ? "搜索回收站" : "搜索"
        hintLabel.stringValue = inTrash
            ? "↩ 恢复 · ⌘⌫ 永久删除 · ⌘T 返回历史 · 放入 30 天后自动删除"
            : "↩ 粘贴 · ⌘1–9 快速粘贴 · ⌘⌫ 删除 · ⌘T 回收站"
    }

    // MARK: - Actions

    /// Shows the most important missing permission, checked each time the panel opens.
    private func updateBanner() {
        let message: String?
        if PasteboardMonitor.isAccessDenied {
            message = "无法读取剪贴板，新复制的内容不会被记录"
            bannerAction = PasteboardMonitor.openPrivacySettings
        } else if !Paster.isTrusted {
            message = "未开启辅助功能权限，无法自动粘贴"
            bannerAction = Paster.openAccessibilitySettings
        } else {
            message = nil
            bannerAction = nil
        }
        if message != nil, banner == nil {
            banner = makeBanner()
        }
        banner?.label.stringValue = message ?? ""
        banner?.view.isHidden = message == nil
        listTopConstraint?.constant = Self.searchHeight + (isBannerVisible ? Self.bannerHeight : 0)
    }

    private func makeBanner() -> (view: NSView, label: NSTextField)? {
        guard let content = listCard.contentView else { return nil }
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemYellow
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The message stretches, so the button sits at the trailing edge.
        label.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        let button = NSButton(title: "打开设置", target: self, action: #selector(bannerButtonClicked))
        button.controlSize = .small
        button.refusesFirstResponder = true

        let view = NSStackView(views: [icon, label, button])
        view.spacing = 6
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.searchHeight),
            view.heightAnchor.constraint(equalToConstant: Self.bannerHeight),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
        ])
        return (view, label)
    }

    @objc private func bannerButtonClicked() {
        let action = bannerAction
        hide()
        action?()
    }
    private func select(_ row: Int) {
        guard rowCount > 0 else { return }
        let row = min(max(row, 0), rowCount - 1)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// History: paste the clip. Trash: restore it to the history.
    private func activate(_ row: Int) {
        guard let clip = clip(at: row) else { return }
        switch list {
        case .history:
            guard let loaded = logged("Load clip text", { try store.text(of: clip.id) }), let text = loaded else { return }
            hide()
            onPaste(text)
        case .trash:
            logged("Restore clip") { try store.restore(clip.id) }
            reload(selecting: row)
        }
    }

    /// History: move the clip to the trash. Trash: delete it permanently.
    private func deleteSelected() {
        let row = tableView.selectedRow
        guard let clip = clip(at: row) else { return }
        switch list {
        case .history: logged("Move clip to trash") { try store.moveToTrash(clip.id) }
        case .trash: logged("Delete clip") { try store.deletePermanently(clip.id) }
        }
        reload(selecting: row)
    }

    @objc private func toggleList() {
        list = list == .history ? .trash : .history
        updateListAppearance()
        reload()
    }

    @objc private func rowDoubleClicked() {
        activate(tableView.clickedRow)
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command else { return false }
        if event.keyCode == 51 { // Delete (backspace)
            deleteSelected()
            return true
        }
        switch event.charactersIgnoringModifiers {
        case "t":
            toggleList()
        case let key? where list == .history && key.count == 1 && ("1"..."9").contains(key):
            if let digit = Int(key) { activate(digit - 1) }
        // The app has no main menu, so standard editing shortcuts are routed by hand.
        case "x": NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case "c":
            if !previewCard.copySelection() {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            }
        case "v": NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case "a": NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case "z": NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        default:
            return false
        }
        return true
    }
}

// MARK: - NSWindowDelegate

extension PanelController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

// MARK: - NSTextFieldDelegate

extension PanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        query = searchField.stringValue
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(tableView.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)): select(tableView.selectedRow + 1)
        case #selector(NSResponder.insertNewline(_:)): activate(tableView.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): hide()
        case #selector(NSResponder.deleteBackward(_:)) where searchField.stringValue.isEmpty: deleteSelected()
        default: return false
        }
        return true
    }
}

// MARK: - NSTableViewDataSource, NSTableViewDelegate

extension PanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipRowView()
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeight(at: row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // reload() updates the preview itself once the new rows and frames are in place.
        if !isReloading {
            updatePreview()
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ClipCellView.identifier, owner: nil) as? ClipCellView ?? ClipCellView()
        let clip = clip(at: row)
        cell.configure(
            text: clip.map { display($0, row: row).text } ?? RowText(string: ""),
            thumbnail: clip?.link.flatMap(thumbnails.image(for:)),
            accessory: accessory(for: row)
        )
        return cell
    }
}
