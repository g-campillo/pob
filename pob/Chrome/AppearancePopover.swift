import AppKit

/// Transparency and blur sliders. Changes apply live over the page and save when you let go.
final class AppearancePopover: NSViewController {
    let transparencySlider = NSSlider(value: 0, minValue: 0, maxValue: 80, target: nil, action: nil)
    let blurSlider = NSSlider(value: 0, minValue: 0, maxValue: 40, target: nil, action: nil)

    private let model: AppearanceModel
    private let transparencyValue = NSTextField(labelWithString: "")
    private let blurValue = NSTextField(labelWithString: "")

    init(model: AppearanceModel) {
        self.model = model
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

    func slidersChanged() {
        model.settings = AppearanceSettings(
            transparency: transparencySlider.doubleValue.rounded() / 100,
            blur: Int(blurSlider.doubleValue.rounded())
        )
        updateValueLabels()
    }

    func slidersFinished() {
        do {
            try model.persist()
        } catch {
            NSLog("pob could not save settings: \(error)")
        }
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
