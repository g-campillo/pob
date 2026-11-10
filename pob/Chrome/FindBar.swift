import AppKit

/// A small glass bar at the top right. Return finds the next match, Shift-Return the previous one, Esc closes.
final class FindBar: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 280
    static let height: CGFloat = 40

    var onSearch: ((String, _ backwards: Bool) -> Void)?
    var onClose: (() -> Void)?

    let field: NSTextField = LiteralTextField()
    let notFoundLabel = NSTextField(labelWithString: "Not found")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let content = addGlass(cornerRadius: 14)

        // The field sits on glass, so it gets a plain fill. Its own background would be a square box.
        let fill = ActiveFill()
        fill.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(fill)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Find on page"
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.setAccessibilityLabel("Find on page")

        notFoundLabel.textColor = .secondaryLabelColor
        notFoundLabel.font = .preferredFont(forTextStyle: .caption1)
        notFoundLabel.isHidden = true

        for subview in [field, notFoundLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: -6),
            fill.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            fill.topAnchor.constraint(equalTo: field.topAnchor, constant: -5),
            fill.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: 5),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            notFoundLabel.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            notFoundLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            notFoundLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 162),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: Self.height) }

    func focus() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func showResult(found: Bool) {
        notFoundLabel.isHidden = found
    }

    func controlTextDidChange(_ notification: Notification) {
        notFoundLabel.isHidden = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            if !field.stringValue.isEmpty { onSearch?(field.stringValue, backwards) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
