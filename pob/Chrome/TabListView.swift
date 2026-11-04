import AppKit

/// The rail's tab rows and its New Tab row. Rows sit on glass, so they use fills, never more glass.
final class TabListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onNewTab: (() -> Void)?
    /// Fires after a reorder drag ends, so the rail can re-check whether the pointer left.
    var onDragEnd: (() -> Void)?
    var favicons: FaviconStore?
    private(set) var isDragging = false

    private static let rowType = NSPasteboard.PasteboardType("com.pob.tab-row")
    private let table = ClickOnlyTable()
    private var records: [TabRecord] = []
    private var activeID: UUID?

    var rowCount: Int { records.count }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("tab"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.registerForDraggedTypes([Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("Tabs")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let newTab = NSButton(title: "New Tab", image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(newTabPressed))
        newTab.isBordered = false
        newTab.imagePosition = .imageLeading
        newTab.alignment = .left
        newTab.contentTintColor = .secondaryLabelColor
        newTab.setAccessibilityLabel("New Tab")

        for subview in [scroll, newTab] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: newTab.topAnchor, constant: -2),
            newTab.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            newTab.trailingAnchor.constraint(equalTo: trailingAnchor),
            newTab.bottomAnchor.constraint(equalTo: bottomAnchor),
            newTab.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(records: [TabRecord], activeID: UUID?) {
        self.records = records
        self.activeID = activeID
        table.reloadData()
        if let activeID, let row = records.firstIndex(where: { $0.id == activeID }) {
            table.scrollRowToVisible(row)
        }
    }

    /// Takes the same path as a click.
    func selectRow(_ index: Int) {
        guard records.indices.contains(index) else { return }
        onSelect?(records[index].id)
    }

    static func displayTitle(for record: TabRecord) -> String {
        if !record.title.isEmpty { return record.title }
        return record.url?.host() ?? "New Tab"
    }

    @objc private func rowClicked() { selectRow(table.clickedRow) }
    @objc private func newTabPressed() { onNewTab?() }

    // MARK: NSTableViewDataSource and NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = records[row]
        let view = tableView.makeView(withIdentifier: TabRow.identifier, owner: nil) as? TabRow ?? TabRow()
        view.identifier = TabRow.identifier
        let host = record.url?.host()
        let title = Self.displayTitle(for: record)
        view.configure(title: title, isActive: record.id == activeID, icon: host.flatMap { favicons?.image(forHost: $0) } ?? FaviconStore.letterTile(for: host ?? title, size: 18))
        view.onClose = { [weak self] in self?.onClose?(record.id) }
        return view
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        isDragging = true
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        onDragEnd?()
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Another window's rail registers the same type, and its row index means nothing here.
        guard info.draggingSource as AnyObject === tableView else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: Self.rowType), let from = Int(text) else { return false }
        let to = from < row ? row - 1 : row
        guard from != to else { return false }
        onMove?(from, to)
        return true
    }
}

/// A click on a row must not take the keyboard from the page or a text field.
final class ClickOnlyTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

/// Marks a row on glass. Set `wantsLayer`, and the color follows the appearance.
final class ActiveFill: NSView {
    override var cornerConfiguration: NSViewCornerConfiguration { .uniformCorners(radius: .containerConcentric(6)) }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }
}

private final class TabRow: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("TabRow")
    var onClose: (() -> Void)?

    private let fill = ActiveFill()
    private let tile = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill.wantsLayer = true

        tile.imageScaling = .scaleProportionallyUpOrDown

        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.isBordered = false
        closeButton.refusesFirstResponder = true
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.setAccessibilityLabel("Close Tab")
        closeButton.alphaValue = 0

        for subview in [fill, tile, label, closeButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 18),
            tile.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(title: String, isActive: Bool, icon: NSImage) {
        label.stringValue = title
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        fill.isHidden = !isActive
        tile.image = icon
        closeButton.alphaValue = 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { closeButton.alphaValue = 0 }

    @objc private func closePressed() { onClose?() }
}
