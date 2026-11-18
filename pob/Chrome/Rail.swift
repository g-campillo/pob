import AppKit

/// The floating glass panel. Everything inside it uses fills and plain controls, never more glass.
final class Rail: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 240
    static let inset: CGFloat = 8
    static let cornerRadius: CGFloat = 18
    /// What the rail takes from the window's left side, with a margin on each side of it.
    static let footprint = width + 2 * inset

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onSettings: (() -> Void)?
    var onDownloads: (() -> Void)?
    var onNavigate: ((CommandID) -> Void)?
    var onAddressFocus: (() -> Void)?
    var onAddressChange: ((String) -> Void)?
    var onAddressEndEditing: (() -> Void)?
    var onPointerExit: (() -> Void)?
    var onProfile: (() -> Void)?

    let addressField: NSTextField = AddressField()
    let tabList = TabListView()
    let suggestions = SwitcherList(selectsFirstRow: false)
    let bookmarks = BookmarksSection()
    let profileButton: NSButton = HoverButton(title: "", target: nil, action: nil)
    private(set) lazy var settingsButton = iconButton("gearshape", label: "Settings", action: #selector(settingsPressed))

    private(set) lazy var downloadsButton = iconButton("arrow.down.circle", label: "Downloads", action: #selector(downloadsPressed))

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

    /// A private window has no other profile to go to, so its button does nothing.
    func update(profileName: String, isPrivate: Bool) {
        let name = isPrivate ? "Private" : profileName
        profileButton.title = name
        profileButton.image = NSImage(systemSymbolName: isPrivate ? "eye.slash" : "person.crop.circle", accessibilityDescription: nil)
        profileButton.isEnabled = !isPrivate
        profileButton.setAccessibilityLabel("Profile: \(name)")
    }

    /// Rows replace the tab list. With none, the tab list comes back.
    func showSuggestions(_ rows: [SwitcherRow]) {
        suggestions.show(rows)
        let (incoming, outgoing) = rows.isEmpty ? (tabList, suggestions) : (suggestions, tabList)
        outgoing.isHidden = true // it takes no space in the stack, so the incoming list fades into its place
        incoming.setShown(true, scales: false)
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
            // Only a row the user arrowed to replaces what they typed.
            if let row = suggestions.selection {
                suggestions.onChoose?(row)
            } else {
                onSubmit?(addressField.stringValue)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        case #selector(NSResponder.moveUp(_:)) where !suggestions.isHidden:
            suggestions.moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)) where !suggestions.isHidden:
            suggestions.moveSelection(by: 1)
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        suggestions.clearPick()
        onAddressChange?(addressField.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        onAddressEndEditing?()
    }

    private func buildGlass() {
        let content = addGlass(cornerRadius: Self.cornerRadius)
        let stack = makeStack()
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 4), // centers the top row on the window buttons
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
        for list in [tabList, suggestions] {
            list.translatesAutoresizingMaskIntoConstraints = false
            list.setContentHuggingPriority(.init(1), for: .vertical)
            list.setContentCompressionResistancePriority(.init(1), for: .vertical)
        }
        suggestions.isHidden = true

        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        profileButton.isBordered = false
        profileButton.target = self
        profileButton.action = #selector(profilePressed)
        profileButton.imagePosition = .imageLeading
        profileButton.lineBreakMode = .byTruncatingTail
        profileButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        profileButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) // a long name gives way to the icons
        let bottomRow = NSStackView(views: [profileButton, bottomSpacer, downloadsButton, settingsButton])
        bottomRow.orientation = .horizontal

        let rows = [topRow, addressRow, bookmarks, tabList, suggestions]
        let stack = NSStackView(views: rows)
        // A gravity area of its own keeps it at the bottom whatever the lists above it show, even neither.
        stack.addView(bottomRow, in: .bottom)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows + [bottomRow] {
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
        let button = HoverButton(image: image, target: self, action: action)
        button.isBordered = false
        button.isRound = true
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    @objc private func backPressed() { onNavigate?(.back) }
    @objc private func forwardPressed() { onNavigate?(.forward) }
    @objc private func reloadPressed() { onNavigate?(.reload) }
    @objc private func settingsPressed() { onSettings?() }
    @objc private func downloadsPressed() { onDownloads?() }
    @objc private func profilePressed() { onProfile?() }
}

extension NSView {
    /// Fills this view with a glass surface and returns the view that holds its content.
    func addGlass(cornerRadius: CGFloat) -> NSView {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = cornerRadius

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = content

        let container = NSGlassEffectContainerView()
        container.contentView = glass

        container.translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

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
        ])
        return content
    }
}

/// For addresses and searches, which must stay as typed, so `--` doesn't turn into a dash.
class LiteralTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { LiteralTextFieldCell.self }
        set {}
    }
}

/// This runs however editing starts. `selectText(_:)` never reaches the field's `becomeFirstResponder`.
private final class LiteralTextFieldCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let text = super.setUpFieldEditorAttributes(textObj)
        if let editor = text as? NSTextView {
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
        }
        return text
    }
}

private final class AddressField: LiteralTextField {
    var onFocus: (() -> Void)?

    /// The first click selects the whole address, so typing replaces it. A drag still selects only what it covers.
    /// While the field is in use, clicks go to its field editor and place the caret as usual.
    override func mouseDown(with event: NSEvent) {
        let wasEditing = currentEditor() != nil
        super.mouseDown(with: event) // returns after the mouse comes up
        if !wasEditing, let editor = currentEditor(), editor.selectedRange.length == 0 {
            editor.selectAll(nil)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocus?()
        }
        return accepted
    }
}
