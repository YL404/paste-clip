import AppKit

/// Borderless panel that takes keyboard focus without activating the app,
/// so the previously active app stays frontmost and receives the paste.
private final class ClipPanel: NSPanel {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyEquivalentHandler?(event) == true || super.performKeyEquivalent(with: event)
    }
}

/// Transparent area around the glass card. A click there counts as a click outside the panel.
private final class MarginView: NSView {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
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

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let thumbnail = NSImageView()
        thumbnail.imageScaling = .scaleAxesIndependently
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 4
        thumbnail.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            thumbnail.widthAnchor.constraint(equalToConstant: ThumbnailCache.size.width),
            thumbnail.heightAnchor.constraint(equalToConstant: ThumbnailCache.size.height),
        ])

        // Hidden views are detached from the stack, so rows without a thumbnail start with text.
        let stack = NSStackView(views: [thumbnail, label])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = label
        imageView = thumbnail
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(text: String, thumbnail: NSImage?) {
        textField?.stringValue = text
        imageView?.image = thumbnail
        imageView?.isHidden = thumbnail == nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class PanelController: NSObject {
    private static let width: CGFloat = 400
    /// Transparent space around the glass card. Liquid Glass draws its shadow beyond its own
    /// frame, and a window edge right at the card would cut that shadow off as a visible ring.
    private static let margin: CGFloat = 32
    private static let rowHeight: CGFloat = 32
    private static let maxVisibleRows = 10
    private static let searchHeight: CGFloat = 44
    private static let pageSize = 50
    private static let maxCachedPages = 6

    private let store: ClipStore
    private let thumbnails: ThumbnailCache
    private let onPaste: (String) -> Void
    private let panel: ClipPanel
    private let searchField = NSTextField()
    private let trashButton = NSButton()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private var list = ClipList.history
    private var query = ""
    private var rowCount = 0
    /// Rows are read from SQLite one page at a time; only a few pages stay in memory.
    private var pages: [Int: [Clip]] = [:]

    init(store: ClipStore, thumbnails: ThumbnailCache, onPaste: @escaping (String) -> Void) {
        self.store = store
        self.thumbnails = thumbnails
        self.onPaste = onPaste
        panel = ClipPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width + 2 * Self.margin, height: Self.searchHeight + 2 * Self.margin),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
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
        updateListAppearance()
        reload()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        // Place the card's top-left corner at the mouse and keep the card itself on screen.
        let size = NSSize(width: Self.width, height: panel.frame.height - 2 * Self.margin)
        var card = NSRect(x: mouse.x, y: mouse.y - size.height, width: size.width, height: size.height)
        if let visible = screen?.visibleFrame {
            card.origin.x = min(max(card.minX, visible.minX), visible.maxX - card.width)
            card.origin.y = min(max(card.minY, visible.minY), visible.maxY - card.height)
        }
        panel.setFrame(card.insetBy(dx: -Self.margin, dy: -Self.margin), display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func hide() {
        panel.orderOut(nil)
        thumbnails.reset()
        // Drop cached rows; the next show reads fresh data anyway.
        rowCount = 0
        pages = [:]
        tableView.reloadData()
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
        tableView.action = #selector(rowClicked)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        let content = NSView()
        for view in [searchField, trashButton, scrollView, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.searchHeight / 2),
            trashButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            trashButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            trashButton.widthAnchor.constraint(equalToConstant: 20),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.searchHeight),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        let glass = NSGlassEffectView()
        glass.cornerRadius = 16
        glass.contentView = content
        glass.translatesAutoresizingMaskIntoConstraints = false

        let container = MarginView()
        container.onMouseDown = { [weak self] in self?.hide() }
        container.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.margin),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.margin),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.margin),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.margin),
        ])
        panel.contentView = container
    }

    // MARK: - Data

    private func reload(selecting row: Int = 0) {
        pages = [:]
        rowCount = logged("Count clips") { try store.count(in: list, matching: query) } ?? 0
        tableView.reloadData()
        if rowCount > 0 {
            select(min(row, rowCount - 1))
        }

        emptyLabel.isHidden = rowCount > 0
        emptyLabel.stringValue = !query.isEmpty ? "没有匹配的记录" : list == .history ? "暂无记录" : "回收站为空"

        let visibleRows = CGFloat(min(max(rowCount, 1), Self.maxVisibleRows))
        let height = Self.searchHeight + visibleRows * (Self.rowHeight + tableView.intercellSpacing.height) + 16
        var frame = panel.frame
        frame.origin.y = frame.maxY - height - 2 * Self.margin
        frame.size.height = height + 2 * Self.margin
        // Only the glass card must stay on screen; the transparent margin may extend past it.
        if let visible = panel.screen?.visibleFrame, frame.minY + Self.margin < visible.minY {
            frame.origin.y = visible.minY - Self.margin
        }
        panel.setFrame(frame, display: panel.isVisible)
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
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    private func updateListAppearance() {
        let inTrash = list == .trash
        trashButton.image = NSImage(systemSymbolName: inTrash ? "trash.fill" : "trash", accessibilityDescription: "回收站")
        trashButton.contentTintColor = inTrash ? .controlAccentColor : .secondaryLabelColor
        searchField.placeholderString = inTrash ? "搜索回收站" : "搜索"
    }

    // MARK: - Actions

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

    @objc private func rowClicked() {
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
        case "c": NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ClipCellView.identifier, owner: nil) as? ClipCellView ?? ClipCellView()
        let clip = clip(at: row)
        cell.configure(text: clip?.preview ?? "", thumbnail: clip?.link.flatMap(thumbnails.image(for:)))
        return cell
    }
}
