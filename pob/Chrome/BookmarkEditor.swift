import AppKit

/// A bookmark's name, address and folder, for a new one or one being changed. The address is read the way the address
/// field reads it, so `example.com` works and words that would be searched for don't.
final class BookmarkEditor: NSViewController {
    enum Field { case name, address }

    struct Entry: Equatable {
        var title: String
        var url: URL
        var folder: String?
    }

    let nameField = NSTextField()
    let addressField: NSTextField = LiteralTextField()
    let folderButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) lazy var saveButton: NSButton = HoverButton(title: "Save", target: self, action: #selector(savePressed))

    private let heading: String
    private let name: String
    private let address: URL?
    private let folder: String?
    private let folders: [String]
    private let focus: Field
    private let onSave: (Entry) -> Void

    init(heading: String, name: String, address: URL?, folder: String?, folders: [String], focus: Field, onSave: @escaping (Entry) -> Void) {
        self.heading = heading
        self.name = name
        self.address = address
        self.folder = folder
        self.folders = folders
        self.focus = focus
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// nil for an address that isn't one, such as words that would be searched for. An address left as it was is kept even
    /// when the address field wouldn't take it, such as a `data:` page saved with ⌘D. A blank name becomes the host.
    static func entry(name: String, address text: String, folder: String?, original: URL?) -> Entry? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        if let original, text == original.absoluteString {
            url = original
        } else if case .url(let typed)? = AddressInput.classify(text) {
            url = typed
        } else {
            return nil
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Entry(title: name.isEmpty ? url.host() ?? url.absoluteString : name, url: url, folder: folder)
    }

    override func loadView() {
        nameField.stringValue = name
        nameField.placeholderString = "Name"
        nameField.setAccessibilityLabel("Name")
        addressField.stringValue = address?.absoluteString ?? ""
        addressField.placeholderString = "Address"
        addressField.cell?.usesSingleLineMode = true
        addressField.setAccessibilityLabel("Address")
        for field in [nameField, addressField] {
            field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }

        // Filled through the menu, because `addItem(withTitle:)` drops a title already there, and a folder can be called
        // "No Folder".
        let none = NSMenuItem(title: "No Folder", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.items = [none] + folders.map { folder in
            let item = NSMenuItem(title: folder, action: nil, keyEquivalent: "")
            item.representedObject = folder
            return item
        }
        folderButton.menu = menu
        folderButton.select(folderButton.itemArray.first { $0.representedObject as? String == folder } ?? none)
        folderButton.isHidden = folders.isEmpty
        folderButton.setAccessibilityLabel("Folder")

        let title = NSTextField(labelWithString: heading)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        saveButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [title, nameField, addressField, folderButton, saveButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(focus == .address ? addressField : nameField)
    }

    @objc private func savePressed() {
        let folder = folderButton.selectedItem?.representedObject as? String
        guard let entry = Self.entry(name: nameField.stringValue, address: addressField.stringValue, folder: folder, original: address) else {
            NSSound.beep()
            view.window?.makeFirstResponder(addressField)
            return
        }
        onSave(entry)
    }
}

/// A folder's name, for a new folder or a new name for one. `onSave` says whether the name was taken, and a refusal beeps.
final class FolderEditor: NSViewController {
    let nameField = NSTextField()
    private(set) lazy var saveButton: NSButton = HoverButton(title: "Save", target: self, action: #selector(savePressed))

    private let heading: String
    private let name: String
    private let onSave: (String) -> Bool

    init(heading: String, name: String, onSave: @escaping (String) -> Bool) {
        self.heading = heading
        self.name = name
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        nameField.stringValue = name
        nameField.placeholderString = "Name"
        nameField.setAccessibilityLabel("Name")
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let title = NSTextField(labelWithString: heading)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        saveButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [title, nameField, saveButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    @objc private func savePressed() {
        if !onSave(nameField.stringValue) { NSSound.beep() }
    }
}
