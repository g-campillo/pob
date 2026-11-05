import AppKit

/// The centered glass panel over a dimmed page. The keyboard stays in the field, which hands Up, Down and Return to the list.
final class SwitcherView: NSView, NSTextFieldDelegate {
    private static let maxListHeight: CGFloat = 400
    private static let panelCornerRadius: CGFloat = 20
    /// The panel grows downward from here, so the field doesn't jump as results change. At full height it's centered.
    private static let panelTopAboveCenter: CGFloat = 230

    var onChoose: ((SwitcherRow) -> Void)?
    var onCancel: (() -> Void)?
    var onQueryChange: ((String) -> Void)?

    let field: NSTextField = LiteralTextField()
    let list = SwitcherList(selectsFirstRow: true)
    private let listHeight: NSLayoutConstraint
    private let pageArea = NSLayoutGuide()
    private lazy var pageLeading = pageArea.leadingAnchor.constraint(equalTo: leadingAnchor)

    /// Where the page starts. The panel centers on the page and sizes from it, so it never reaches the rail.
    var pageInset: CGFloat {
        get { pageLeading.constant }
        set { pageLeading.constant = newValue }
    }

    override init(frame: NSRect) {
        listHeight = list.heightAnchor.constraint(equalToConstant: 0)
        super.init(frame: frame)
        list.onChoose = { [weak self] in self?.onChoose?($0) }

        let dimming = NSView(frame: bounds)
        dimming.autoresizingMask = [.width, .height]
        dimming.wantsLayer = true
        dimming.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        dimming.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(dimmingClicked)))
        addSubview(dimming)

        addLayoutGuide(pageArea)
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        let content = panel.addGlass(cornerRadius: Self.panelCornerRadius)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .title2)
        field.placeholderString = "Search or enter address"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.setAccessibilityLabel("Search")

        for subview in [field, list] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }

        // In a short window the panel keeps its margins, and the list gives up height and scrolls.
        // Both stay under `.windowSizeStayPut`, or they'd stretch the window instead. Much lower, and the glass flattens the list.
        let topLine = panel.topAnchor.constraint(equalTo: centerYAnchor, constant: -Self.panelTopAboveCenter)
        topLine.priority = .dragThatCannotResizeWindow
        listHeight.priority = .init(NSLayoutConstraint.Priority.dragThatCannotResizeWindow.rawValue - 1)
        NSLayoutConstraint.activate([
            topLine,
            listHeight,
            pageLeading,
            pageArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.centerXAnchor.constraint(equalTo: pageArea.centerXAnchor),
            panel.widthAnchor.constraint(equalTo: pageArea.widthAnchor, multiplier: 0.56),
            panel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            list.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            list.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Starts a new search with the keyboard in the field. Nothing here animates, so typing can start at once.
    func open() {
        field.stringValue = ""
        list.clearPick()
        isHidden = false
        focus()
    }

    func show(rows: [SwitcherRow]) {
        // With nothing typed the rows are just there to browse, so none is marked until the arrows pick one.
        list.selectsFirstRow = AddressInput.classify(field.stringValue) != nil
        list.show(rows)
        listHeight.constant = min(list.contentHeight, Self.maxListHeight)
    }

    /// Asking a field that's already being edited to take the keyboard would select what's been typed.
    func focus() {
        guard field.currentEditor() == nil else { return }
        window?.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        // Tab moves through the rows too, because it would otherwise leave the field for something behind the panel.
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            list.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            list.moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            if let row = list.selection {
                onChoose?(row)
            } else if !list.rows.isEmpty { // with no rows the window is empty, and closing would leave nothing on screen
                onCancel?()
            }
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default:
            return false
        }
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        list.clearPick()
        onQueryChange?(field.stringValue)
    }

    @objc private func dimmingClicked() { onCancel?() }
}

/// Results with section headers, for the switcher and the rail's address field.
/// The text field above keeps the keyboard and hands over Up, Down and Return.
final class SwitcherList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 40
    private static let headerHeight: CGFloat = 24

    private enum Item {
        case header(String), row(SwitcherRow)

        var row: SwitcherRow? {
            if case .row(let row) = self { row } else { nil }
        }
    }

    var onChoose: ((SwitcherRow) -> Void)?
    /// When on, Return always has a row to choose. When off, nothing's marked until the arrows pick a row.
    var selectsFirstRow: Bool

    private let table = ClickOnlyTable()
    private var items: [Item] = []
    /// The row the arrows landed on, kept when history reloads the list around it.
    private var pick: SwitcherRow.Target?

    var rows: [SwitcherRow] { items.compactMap(\.row) }

    var selection: SwitcherRow? {
        items.indices.contains(table.selectedRow) ? items[table.selectedRow].row : nil
    }

    var contentHeight: CGFloat {
        items.reduce(0) { $0 + height(of: $1) + table.intercellSpacing.height }
    }

    init(selectsFirstRow: Bool) {
        self.selectsFirstRow = selectsFirstRow
        super.init(frame: .zero)

        table.addTableColumn(NSTableColumn(identifier: .init("row")))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityLabel("Results")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ rows: [SwitcherRow]) {
        items = rows.indices.flatMap { index -> [Item] in
            let row = rows[index]
            let startsSection = !row.section.isEmpty && (index == 0 || rows[index - 1].section != row.section)
            return startsSection ? [.header(row.section), .row(row)] : [.row(row)]
        }
        table.reloadData()
        if !items.isEmpty {
            table.scrollRowToVisible(0)
        }
        let picked = pick.flatMap { pick in items.firstIndex { $0.row?.target == pick } }
        select(picked ?? (selectsFirstRow ? items.firstIndex { $0.row != nil } : nil))
    }

    /// Skips headers and stops at the ends. Above the first row, a list with no default row goes back to having none.
    func moveSelection(by step: Int) {
        let selectable = items.indices.filter { items[$0].row != nil }
        guard !selectable.isEmpty else { return }
        let position = min((selectable.firstIndex(of: table.selectedRow) ?? -1) + step, selectable.count - 1)
        let index = position >= 0 ? selectable[position] : (selectsFirstRow ? selectable[0] : nil)
        select(index)
        pick = index.flatMap { items[$0].row?.target }
    }

    /// New text means new results, so an old pick no longer counts.
    func clearPick() {
        pick = nil
    }

    /// Takes the same path as a click. `index` counts headers, as the table does.
    func chooseRow(_ index: Int) {
        guard items.indices.contains(index), let row = items[index].row else { return }
        onChoose?(row)
    }

    private func select(_ index: Int?) {
        table.selectRowIndexes(index.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        if let index {
            table.scrollRowToVisible(index)
        }
    }

    private func height(of item: Item) -> CGFloat {
        item.row == nil ? Self.headerHeight : Self.rowHeight
    }

    @objc private func rowClicked() { chooseRow(table.clickedRow) }

    // MARK: NSTableViewDataSource and NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(of: items[row]) }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].row != nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SwitcherRowBackground() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SwitcherCell.identifier, owner: nil) as? SwitcherCell ?? SwitcherCell()
        cell.identifier = SwitcherCell.identifier
        switch items[row] {
        case .header(let title): cell.configure(header: title)
        case .row(let row): cell.configure(row: row)
        }
        return cell
    }
}

/// Rows sit on glass, so the selected one gets a fill, never more glass.
private final class SwitcherRowBackground: NSTableRowView {
    private let fill = ActiveFill()

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill.wantsLayer = true
        fill.isHidden = true
        fill.frame = bounds
        fill.autoresizingMask = [.width, .height]
        addSubview(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isSelected: Bool {
        didSet { fill.isHidden = !isSelected }
    }
}

private final class SwitcherCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("SwitcherCell")

    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(header: String) {
        title.stringValue = header
        title.font = .preferredFont(forTextStyle: .caption1)
        title.textColor = .secondaryLabelColor
        subtitle.isHidden = true
        setAccessibilityLabel(header)
    }

    func configure(row: SwitcherRow) {
        title.stringValue = row.title
        title.font = .preferredFont(forTextStyle: .body)
        title.textColor = .labelColor
        subtitle.stringValue = row.subtitle
        subtitle.isHidden = row.subtitle.isEmpty
        setAccessibilityLabel(row.title)
    }
}
