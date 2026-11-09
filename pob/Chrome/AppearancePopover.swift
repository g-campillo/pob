import AppKit

/// Transparency and blur sliders, the site's ad block switch, and the way to Settings. Changes apply live over the page and save when you let go.
final class AppearancePopover: NSViewController {
    let transparencySlider = NSSlider(value: 0, minValue: 0, maxValue: 80, target: nil, action: nil)
    let blurSlider = NSSlider(value: 0, minValue: 0, maxValue: 40, target: nil, action: nil)
    /// Nil when the page has no host to switch.
    let blockingCheckbox: NSButton?

    private let model: AppearanceModel
    private let onToggleBlocking: () -> Void
    private let onOpenSettings: () -> Void
    private let transparencyValue = NSTextField(labelWithString: "")
    private let blurValue = NSTextField(labelWithString: "")

    init(
        model: AppearanceModel, site: String? = nil, isBlocking: Bool = true,
        onToggleBlocking: @escaping () -> Void = {}, onOpenSettings: @escaping () -> Void = {}
    ) {
        self.model = model
        blockingCheckbox = site.map { NSButton(checkboxWithTitle: "Block ads on \($0)", target: nil, action: nil) }
        blockingCheckbox?.state = isBlocking ? .on : .off
        self.onToggleBlocking = onToggleBlocking
        self.onOpenSettings = onOpenSettings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        transparencySlider.doubleValue = (model.settings.transparency * 100).rounded()
        blurSlider.doubleValue = Double(model.settings.blur)
        for slider in [transparencySlider, blurSlider] {
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(sliderMoved)
            slider.widthAnchor.constraint(equalToConstant: 170).isActive = true
        }
        transparencySlider.setAccessibilityLabel("Transparency")
        blurSlider.setAccessibilityLabel("Blur")
        updateValueLabels()

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Transparency"), transparencySlider, transparencyValue],
            [NSTextField(labelWithString: "Blur"), blurSlider, blurValue],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 2).width = 38
        if let blockingCheckbox {
            blockingCheckbox.target = self
            blockingCheckbox.action = #selector(toggleBlocking)
            let row = grid.addRow(with: [blockingCheckbox])
            row.mergeCells(in: NSRange(location: 0, length: 3))
            row.topPadding = 4
        }
        let settingsButton = NSButton(title: "Settings…", target: self, action: #selector(openSettings))
        let settingsRow = grid.addRow(with: [settingsButton])
        settingsRow.mergeCells(in: NSRange(location: 0, length: 3))
        settingsRow.topPadding = 4
        grid.cell(for: settingsButton)?.xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        view = container
    }

    /// Keyboard changes have no mouse-up, so closing the popover saves them too.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        slidersFinished()
    }

    func slidersChanged() {
        var settings = model.settings // keeps the search engine
        settings.transparency = transparencySlider.doubleValue.rounded() / 100
        settings.blur = Int(blurSlider.doubleValue.rounded())
        model.settings = settings
        updateValueLabels()
    }

    func slidersFinished() {
        do {
            try model.persist()
        } catch {
            NSLog("pob could not save settings: \(error)")
        }
    }

    /// AppKit has already flipped the box.
    @objc private func toggleBlocking() {
        onToggleBlocking()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func sliderMoved() {
        slidersChanged()
        if NSApp.currentEvent?.type == .leftMouseUp {
            slidersFinished()
        }
    }

    private func updateValueLabels() {
        transparencyValue.stringValue = "\(Int(transparencySlider.doubleValue.rounded()))%"
        blurValue.stringValue = "\(Int(blurSlider.doubleValue.rounded()))"
    }
}
