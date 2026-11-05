import AppKit

/// This run's downloads, with progress, Reveal in Finder, and Retry for the ones that failed.
final class DownloadsPopover: NSViewController {
    private let downloads: Downloads
    private let onRetry: (UUID) -> Void
    private let stack = NSStackView()
    private var bars: [UUID: NSProgressIndicator] = [:]
    private var shownRows: [[AnyHashable]] = []

    init(downloads: Downloads, onRetry: @escaping (UUID) -> Void) {
        self.downloads = downloads
        self.onRetry = onRetry
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 300),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        view = container
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        downloads.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        downloads.onChange = nil
    }

    /// Progress alone moves the bars. A new row or a changed state rebuilds the list.
    func refresh() {
        let items = downloads.items
        let rows = items.map { [AnyHashable($0.id), AnyHashable($0.state)] }
        guard rows == shownRows else {
            shownRows = rows
            rebuild(items)
            return
        }
        for item in items { bars[item.id]?.doubleValue = item.progress }
    }

    private func rebuild(_ items: [DownloadItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        bars = [:]
        itemsByButton = [:]
        if items.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: "No downloads yet"))
        }
        for item in items.reversed() {
            let row = makeRow(item)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func makeRow(_ item: DownloadItem) -> NSView {
        let name = NSTextField(labelWithString: item.filename)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let trailing: NSView
        switch item.state {
        case .running:
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.minValue = 0
            bar.maxValue = 1
            bar.doubleValue = item.progress
            bar.isIndeterminate = false
            bar.setAccessibilityLabel("Progress of \(item.filename)")
            bars[item.id] = bar
            trailing = bar
        case .finished:
            trailing = button("Show in Finder", #selector(reveal(_:)), item)
        case .failed:
            trailing = button("Retry", #selector(retry(_:)), item)
        }
        let status = item.state == .failed ? NSTextField(labelWithString: "Failed") : nil
        status?.textColor = .secondaryLabelColor
        let row = NSStackView(views: [name, trailing] + (status.map { [$0] } ?? []))
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        if let bar = trailing as? NSProgressIndicator {
            bar.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        return row
    }

    private var itemsByButton: [ObjectIdentifier: DownloadItem] = [:]

    private func button(_ title: String, _ action: Selector, _ item: DownloadItem) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.setAccessibilityLabel("\(title), \(item.filename)")
        itemsByButton[ObjectIdentifier(button)] = item
        return button
    }

    /// A file moved or deleted since it finished opens its folder instead, because selecting nothing does nothing.
    @objc private func reveal(_ sender: NSButton) {
        guard let item = itemsByButton[ObjectIdentifier(sender)] else { return }
        let exists = FileManager.default.fileExists(atPath: item.destination.path)
        NSWorkspace.shared.activateFileViewerSelecting([exists ? item.destination : item.destination.deletingLastPathComponent()])
    }

    @objc private func retry(_ sender: NSButton) {
        guard let item = itemsByButton[ObjectIdentifier(sender)] else { return }
        onRetry(item.id)
    }
}
