import AppKit

/// This run's downloads, with progress, Reveal in Finder, and Retry for the ones that failed.
final class DownloadsPopover: NSViewController {
    private let downloads: Downloads
    private let onRetry: (UUID) -> Void
    private let stack = NSStackView()
    private var bars: [UUID: NSProgressIndicator] = [:]
    private var shownRows: [[AnyHashable]]? // nil until the first build, so an empty list still builds

    init(downloads: Downloads, onRetry: @escaping (UUID) -> Void) {
        self.downloads = downloads
        self.onRetry = onRetry
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Tall enough for a few rows. More scroll.
    private static let maxHeight: CGFloat = 400

    private let scrollView = NSScrollView()

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: 300),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -14),
        ])
        view = scrollView
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
        for item in items { show(item.progress, on: bars[item.id]) }
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
        // The popover grows to fit its rows, up to a limit, and scrolls past it.
        stack.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 300, height: min(stack.fittingSize.height + 28, Self.maxHeight))
    }

    /// With no length from the server there's no fraction, so the bar just moves.
    private func show(_ progress: Double, on bar: NSProgressIndicator?) {
        guard let bar else { return }
        bar.isIndeterminate = progress <= 0
        if bar.isIndeterminate { bar.startAnimation(nil) } else { bar.doubleValue = progress }
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
            bar.isIndeterminate = false
            show(item.progress, on: bar)
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

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
