import AppKit

/// The floating glass panel. Everything inside it uses fills and plain controls, never more glass.
final class Rail: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 240
    static let inset: CGFloat = 8

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onSettings: (() -> Void)?
    var onNavigate: ((CommandID) -> Void)?
    var onAddressFocus: (() -> Void)?
    var onAddressEndEditing: (() -> Void)?
    var onPointerExit: (() -> Void)?

    let addressField: NSTextField = AddressField()
    let tabList = TabListView()
    let pinned = PinnedBookmarksView()
    private(set) lazy var settingsButton = iconButton("gearshape", label: "Settings", action: #selector(settingsPressed))

    private lazy var backButton = iconButton("chevron.left", label: "Back", action: #selector(backPressed))
    private lazy var forwardButton = iconButton("chevron.right", label: "Forward", action: #selector(forwardPressed))
    private lazy var reloadButton = iconButton("arrow.clockwise", label: "Reload", action: #selector(reloadPressed))
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildGlass()
        tabList.onDragEnd = { [weak self] in self?.onPointerExit?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(url: URL?, canGoBack: Bool, canGoForward: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        guard addressField.currentEditor() == nil else { return }
        addressField.stringValue = url?.scheme == "about" ? "" : url?.absoluteString ?? ""
    }

    func update(pinned bookmarks: [Bookmark], favicons: FaviconStore) {
        pinned.update(bookmarks: bookmarks, favicons: favicons)
        pinned.isHidden = bookmarks.isEmpty // a hidden row takes no space in the stack
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        guard !tabList.isDragging else { return }
        onPointerExit?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(addressField.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        onAddressEndEditing?()
    }

    private func buildGlass() {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 18

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = content

        let container = NSGlassEffectContainerView()
        container.contentView = glass

        container.translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        let stack = makeStack()
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.topAnchor),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    private func makeStack() -> NSStackView {
        // The window buttons float over the left of this row, and dragging the empty space moves the window.
        let dragArea = TopDragStrip()
        dragArea.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let topRow = NSStackView(views: [dragArea, backButton, forwardButton, reloadButton])
        topRow.orientation = .horizontal
        topRow.spacing = 4
        topRow.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let addressRow = makeAddressRow()

        // The list is the part that shrinks and scrolls when the window is short.
        tabList.translatesAutoresizingMaskIntoConstraints = false
        tabList.setContentHuggingPriority(.init(1), for: .vertical)
        tabList.setContentCompressionResistancePriority(.init(1), for: .vertical)

        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomRow = NSStackView(views: [bottomSpacer, settingsButton])
        bottomRow.orientation = .horizontal

        pinned.translatesAutoresizingMaskIntoConstraints = false
        pinned.isHidden = true

        let stack = NSStackView(views: [topRow, addressRow, pinned, tabList, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in [topRow, addressRow, pinned, tabList, bottomRow] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func makeAddressRow() -> NSView {
        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 9
        fill.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        fill.translatesAutoresizingMaskIntoConstraints = false

        addressField.isBordered = false
        addressField.drawsBackground = false
        addressField.focusRingType = .none
        addressField.placeholderString = "Search or enter address"
        addressField.lineBreakMode = .byTruncatingTail
        addressField.cell?.usesSingleLineMode = true
        addressField.delegate = self
        addressField.setAccessibilityLabel("Address")
        addressField.translatesAutoresizingMaskIntoConstraints = false
        (addressField as? AddressField)?.onFocus = { [weak self] in self?.onAddressFocus?() }
        fill.addSubview(addressField)

        NSLayoutConstraint.activate([
            fill.heightAnchor.constraint(equalToConstant: 30),
            addressField.leadingAnchor.constraint(equalTo: fill.leadingAnchor, constant: 10),
            addressField.trailingAnchor.constraint(equalTo: fill.trailingAnchor, constant: -10),
            addressField.centerYAnchor.constraint(equalTo: fill.centerYAnchor),
        ])
        return fill
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    @objc private func backPressed() { onNavigate?(.back) }
    @objc private func forwardPressed() { onNavigate?(.forward) }
    @objc private func reloadPressed() { onNavigate?(.reload) }
    @objc private func settingsPressed() { onSettings?() }
}

private final class AddressField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocus?()
        }
        return accepted
    }
}

/// Pinned bookmarks as icons that wrap onto new rows. They sit on glass, so they stay plain buttons.
final class PinnedBookmarksView: NSView {
    var onOpen: ((Bookmark) -> Void)?
    var onUnpin: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?

    private static let columns = 7 // fits the rail's fixed width
    private static let cell: CGFloat = 28
    private static let gap: CGFloat = 4
    private var bookmarks: [Bookmark] = []

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let rows = (bookmarks.count + Self.columns - 1) / Self.columns
        return NSSize(width: NSView.noIntrinsicMetric, height: rows == 0 ? 0 : CGFloat(rows) * (Self.cell + Self.gap) - Self.gap)
    }

    func update(bookmarks: [Bookmark], favicons: FaviconStore) {
        self.bookmarks = bookmarks
        subviews.forEach { $0.removeFromSuperview() }
        for (index, bookmark) in bookmarks.enumerated() {
            let host = bookmark.url.host() ?? bookmark.title
            let icon = (bookmark.url.host().flatMap(favicons.image(forHost:))) ?? FaviconStore.letterTile(for: host, size: 20)
            icon.size = NSSize(width: 20, height: 20)
            let button = NSButton(image: icon, target: self, action: #selector(pressed(_:)))
            button.isBordered = false
            button.refusesFirstResponder = true
            button.tag = index
            button.toolTip = bookmark.title
            button.setAccessibilityLabel(bookmark.title)
            let menu = NSMenu()
            for (title, action) in [("Unpin", #selector(unpin(_:))), ("Remove", #selector(remove(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
            button.menu = menu
            addSubview(button)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (index, button) in subviews.enumerated() {
            let step = Self.cell + Self.gap
            button.frame = NSRect(x: CGFloat(index % Self.columns) * step, y: CGFloat(index / Self.columns) * step, width: Self.cell, height: Self.cell)
        }
    }

    @objc private func pressed(_ sender: NSButton) { onOpen?(bookmarks[sender.tag]) }
    @objc private func unpin(_ sender: NSMenuItem) { onUnpin?(bookmarks[sender.tag].id) }
    @objc private func remove(_ sender: NSMenuItem) { onRemove?(bookmarks[sender.tag].id) }
}
