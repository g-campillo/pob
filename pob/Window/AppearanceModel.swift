import Foundation

final class AppearanceModel {
    var onChange: (() -> Void)?

    var settings: AppearanceSettings {
        get { storedSettings }
        set {
            storedSettings = newValue.clamped
            onChange?()
        }
    }

    var reduceTransparency: Bool {
        didSet { onChange?() }
    }

    private(set) var isSnappedOpaque = false

    var effective: EffectiveAppearance {
        if isSnappedOpaque || reduceTransparency {
            return EffectiveAppearance(pageAlpha: 1, blurRadius: 0)
        }
        return EffectiveAppearance(pageAlpha: 1 - storedSettings.transparency, blurRadius: storedSettings.blur)
    }

    private let store: SettingsStore
    private var storedSettings: AppearanceSettings

    init(store: SettingsStore, reduceTransparency: Bool) {
        self.store = store
        self.reduceTransparency = reduceTransparency
        storedSettings = store.load()
    }

    func toggleSnap() {
        isSnappedOpaque.toggle()
        onChange?()
    }

    func persist() throws {
        try store.save(storedSettings)
    }
}
