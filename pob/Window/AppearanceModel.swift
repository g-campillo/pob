import Foundation

final class AppearanceModel {
    // shortcut: a closed window leaves a no-op closure behind, add removal if that ever matters
    private var observers: [() -> Void] = []

    func addObserver(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }

    private func notify() {
        observers.forEach { $0() }
    }

    var settings: AppearanceSettings {
        get { storedSettings }
        set {
            storedSettings = newValue.clamped
            notify()
        }
    }

    var reduceTransparency: Bool {
        didSet { notify() }
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
        notify()
    }

    func persist() throws {
        try store.save(storedSettings)
    }
}
