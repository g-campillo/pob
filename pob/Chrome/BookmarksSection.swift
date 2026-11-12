import AppKit

/// One line of the Bookmarks section: a folder, or a bookmark in no folder or in an open one.
enum BookmarkRow: Equatable {
    case folder(String, isOpen: Bool)
    case bookmark(Bookmark, inFolder: Bool)

    enum Key: Hashable {
        case folder(String)
        case bookmark(UUID)
    }

    /// Stays the same while what the row shows changes, so the list can tell a changed row from a new one.
    var key: Key {
        switch self {
        case .folder(let name, _): .folder(name)
        case .bookmark(let bookmark, _): .bookmark(bookmark.id)
        }
    }
}

/// The rail's Bookmarks section: a header that opens and closes it, with Add and New Folder, over a list of folders and
/// bookmarks. It starts closed in every window. Rows sit on glass, so they use fills, never more glass.
final class BookmarksSection: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 28
    static let rowGap: CGFloat = 2
    /// Seven rows. More scroll inside the list.
    static let maxListHeight: CGFloat = 7 * (rowHeight + rowGap)
    /// However many rows there are, a short window keeps room for the tabs below.
    static let maxWindowShare: CGFloat = 0.4

    var onOpen: ((Bookmark) -> Void)?
    /// The view is where an editor should point from.
    var onRename: ((Bookmark, NSView) -> Void)?
    var onEditAddress: ((Bookmark, NSView) -> Void)?
    /// nil takes it out of every folder.
    var onMove: ((UUID, String?) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onAdd: ((NSView) -> Void)?
    var onNewFolder: ((NSView) -> Void)?
    var onRenameFolder: ((String, NSView) -> Void)?
    var onDeleteFolder: ((String) -> Void)?
    var favicons: FaviconStore?

    private(set) var isExpanded = false
    private(set) var rows: [BookmarkRow] = []
    private(set) lazy var toggleButton = makeToggleButton()
    private(set) lazy var newFolderButton = iconButton("folder.badge.plus", label: "New Folder", action: #selector(newFolderPressed))
    private(set) lazy var addButton = iconButton("plus", label: "Add Bookmark", action: #selector(addPressed))
    /// What the list would like to be. Below the window's own size, so a short window can take some back.
    private(set) lazy var listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)

    private let table = ClickOnlyTable()
    private let scroll = NSScrollView()
    private var windowLimit: NSLayoutConstraint?
    private var folders: [String] = []
    private var bookmarks: [Bookmark] = []
    private var openFolders: Set<String> = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setContentHuggingPriority(.defaultHigh, for: .vertical)

        let column = NSTableColumn(identifier: .init("bookmark"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: Self.rowGap)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityLabel("Bookmarks")
        table.menu = NSMenu()
        table.menu?.delegate = self

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [toggleButton, spacer, newFolderButton, addButton])
        header.orientation = .horizontal
        header.spacing = 2

        for subview in [header, scroll] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Under the window's hold on its own size, or the window grows to fit the list instead of the list shrinking.
        listHeight.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 10)
        listHeight.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowLimit?.isActive = false
        windowLimit = window?.contentView.map { scroll.heightAnchor.constraint(lessThanOrEqualTo: $0.heightAnchor, multiplier: Self.maxWindowShare) }
        windowLimit?.isActive = true
    }

    // MARK: Rows

    /// Folders first, in their order, each followed by its bookmarks when open. Then the bookmarks in no folder.
    /// A bookmark naming a folder that isn't listed shows with those, so it can't go missing.
    static func rows(folders: [String], bookmarks: [Bookmark], openFolders: Set<String>) -> [BookmarkRow] {
        let listed = Set(folders)
        var inFolder: [String: [Bookmark]] = [:]
        var loose: [BookmarkRow] = []
        for bookmark in bookmarks {
            if let folder = bookmark.folder, listed.contains(folder) {
                inFolder[folder, default: []].append(bookmark)
            } else {
                loose.append(.bookmark(bookmark, inFolder: false))
            }
        }
        var rows: [BookmarkRow] = []
        for folder in folders {
            let isOpen = openFolders.contains(folder)
            rows.append(.folder(folder, isOpen: isOpen))
            if isOpen { rows += (inFolder[folder] ?? []).map { .bookmark($0, inFolder: true) } }
        }
        return rows + loose
    }

    /// Every change to any tab lands here too. Rows are only rebuilt when the list itself changed.
    func update(folders: [String], bookmarks: [Bookmark]) {
        self.folders = folders
        self.bookmarks = bookmarks
        openFolders.formIntersection(folders)
        showRows(animated: false)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        isExpanded = expanded
        toggleButton.image = Self.chevron(open: expanded)
        toggleButton.toolTip = expanded ? "Hide Bookmarks" : "Show Bookmarks"
        showRows(animated: animated)
    }

    /// Takes the same path as a click: a folder opens or closes, and a bookmark opens.
    func clickRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .folder(let name, let isOpen):
            if isOpen { openFolders.remove(name) } else { openFolders.insert(name) }
            showRows(animated: true)
        case .bookmark(let bookmark, _):
            onOpen?(bookmark)
        }
    }

    /// Opens the section and the bookmark's folder, and scrolls to it, so one just added can be seen.
    func reveal(bookmark id: UUID) {
        if let folder = bookmarks.first(where: { $0.id == id })?.folder { openFolders.insert(folder) }
        setExpanded(true, animated: true)
        if let index = rows.firstIndex(where: { $0.key == .bookmark(id) }) { table.scrollRowToVisible(index) }
    }

    func reveal(folder name: String) {
        setExpanded(true, animated: true)
        if let index = rows.firstIndex(where: { $0.key == .folder(name) }) { table.scrollRowToVisible(index) }
    }

    private func showRows(animated: Bool) {
        let previous = rows.map(\.key)
        rows = Self.rows(folders: folders, bookmarks: bookmarks, openFolders: openFolders)
        let keys = rows.map(\.key)
        if keys != previous, animated, Motion.isOn {
            // The difference lists removals first, from the bottom up, as the table wants them.
            table.beginUpdates()
            for change in keys.difference(from: previous) {
                switch change {
                case .remove(let offset, _, _): table.removeRows(at: [offset], withAnimation: [.effectFade, .slideUp])
                case .insert(let offset, _, _): table.insertRows(at: [offset], withAnimation: [.effectFade, .slideDown])
                }
            }
            table.endUpdates()
        } else if keys != previous {
            table.reloadData()
        }
        // An icon can arrive with nothing else changed. Only rows with a view are touched, as there can be thousands.
        table.enumerateAvailableRowViews { rowView, row in
            guard rows.indices.contains(row) else { return }
            (rowView.view(atColumn: 0) as? BookmarkCell)?.configure(rows[row], favicons: favicons)
        }
        fitHeight(animated: animated)
    }

    /// A constraint doesn't follow the spring, so the height eases on AppKit's own curve. A close hides the list once
    /// it's down, unless an open came in meanwhile and cut it short.
    private func fitHeight(animated: Bool) {
        let height = isExpanded ? min(CGFloat(rows.count) * (Self.rowHeight + Self.rowGap), Self.maxListHeight) : 0
        if isExpanded { scroll.isHidden = false }
        let hideIfClosed = { [weak self] in
            guard let self, !isExpanded else { return }
            scroll.isHidden = true
        }
        guard animated, Motion.isOn else {
            listHeight.constant = height // set directly, which also stops a change still running
            hideIfClosed()
            return
        }
        Motion.animate(Motion.spring, { listHeight.animator().constant = height }, completion: hideIfClosed)
    }

    // MARK: Header

    static func chevron(open: Bool) -> NSImage {
        let symbol = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: nil) ?? NSImage()
        return symbol.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) ?? symbol
    }

    private func makeToggleButton() -> NSButton {
        let button = HoverButton(title: "Bookmarks", image: Self.chevron(open: false), target: self, action: #selector(togglePressed))
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Show Bookmarks"
        return button
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = HoverButton(image: image, target: self, action: action)
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    @objc private func togglePressed() { setExpanded(!isExpanded, animated: true) }
    @objc private func addPressed() { onAdd?(addButton) }
    @objc private func newFolderPressed() { onNewFolder?(newFolderButton) }
    @objc private func rowClicked() { clickRow(table.clickedRow) }

    // MARK: Right-click

    /// What a right-click on the row offers. Nothing below the rows.
    func menu(forRow index: Int) -> NSMenu {
        let menu = NSMenu()
        menu.items = menuItems(forRow: index)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items = menuItems(forRow: table.clickedRow)
    }

    /// Each item carries what it does, so it acts on the row it was made for even if the list changes while the menu is up.
    private func menuItems(forRow index: Int) -> [NSMenuItem] {
        guard rows.indices.contains(index) else { return [] }
        let row = rows[index]
        switch row {
        case .folder(let name, _):
            return [
                item("Rename Folder…") { [weak self] in
                    guard let self else { return }
                    onRenameFolder?(name, anchor(for: row.key))
                },
                .separator(),
                item("Delete Folder") { [weak self] in self?.onDeleteFolder?(name) },
            ]
        case .bookmark(let bookmark, _):
            var items = [
                item("Rename…") { [weak self] in
                    guard let self else { return }
                    onRename?(bookmark, anchor(for: row.key))
                },
                item("Edit Address…") { [weak self] in
                    guard let self else { return }
                    onEditAddress?(bookmark, anchor(for: row.key))
                },
            ]
            if !folders.isEmpty {
                let submenu = NSMenu()
                let none = item("No Folder") { [weak self] in self?.onMove?(bookmark.id, nil) }
                none.state = bookmark.folder == nil ? .on : .off
                submenu.items = [none, .separator()] + folders.map { folder in
                    let choice = item(folder) { [weak self] in self?.onMove?(bookmark.id, folder) }
                    choice.state = bookmark.folder == folder ? .on : .off
                    return choice
                }
                let move = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
                move.submenu = submenu
                items.append(move)
            }
            return items + [.separator(), item("Delete") { [weak self] in self?.onDelete?(bookmark.id) }]
        }
    }

    private func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = run
        return item
    }

    @objc private func menuItemChosen(_ item: NSMenuItem) {
        (item.representedObject as? () -> Void)?()
    }

    /// The row's view if it has one, so an editor points at the row, or else the list.
    private func anchor(for key: BookmarkRow.Key) -> NSView {
        rows.firstIndex { $0.key == key }.flatMap { table.view(atColumn: 0, row: $0, makeIfNecessary: false) } ?? table
    }

    // MARK: NSTableViewDataSource and NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: BookmarkCell.identifier, owner: nil) as? BookmarkCell ?? BookmarkCell()
        view.identifier = BookmarkCell.identifier
        view.configure(rows[row], favicons: favicons)
        return view
    }
}

/// A folder or a bookmark. The whole row is a click target, and a fill shows while the pointer is over it.
private final class BookmarkCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("BookmarkCell")
    private static let inset: CGFloat = 8
    private static let indent: CGFloat = 16

    private let fill = ActiveFill()
    private let tile = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private lazy var tileLeading = tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset)

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill.isHidden = true
        tile.imageScaling = .scaleProportionallyUpOrDown

        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor

        chevron.contentTintColor = .tertiaryLabelColor

        // The tile is the first image view, which the tests rely on.
        for subview in [fill, tile, label, chevron] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            tileLeading,
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 16),
            tile.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ row: BookmarkRow, favicons: FaviconStore?) {
        switch row {
        case .folder(let name, let isOpen):
            tile.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            tile.contentTintColor = .secondaryLabelColor
            label.stringValue = name
            chevron.image = BookmarksSection.chevron(open: isOpen)
            chevron.isHidden = false
            tileLeading.constant = Self.inset
            toolTip = nil
            setAccessibilityLabel(name)
        case .bookmark(let bookmark, let inFolder):
            let host = bookmark.url.host()
            tile.image = host.flatMap { favicons?.image(forHost: $0) } ?? FaviconStore.letterTile(for: host ?? bookmark.title, size: 16)
            tile.contentTintColor = nil
            label.stringValue = bookmark.title
            chevron.isHidden = true
            tileLeading.constant = inFolder ? Self.inset + Self.indent : Self.inset
            toolTip = bookmark.url.absoluteString // the address tells apart two with the same name
            setAccessibilityLabel(bookmark.title)
        }
    }

    /// Not in `configure`, which also runs on the row the pointer may be on.
    override func prepareForReuse() {
        super.prepareForReuse()
        fill.isHidden = true
    }

    /// The whole row is a click target.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { fill.isHidden = false }
    override func mouseExited(with event: NSEvent) { fill.isHidden = true }
}
