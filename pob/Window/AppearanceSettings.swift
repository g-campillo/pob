import Foundation

struct AppearanceSettings: Codable, Equatable {
    var transparency: Double
    var blur: Int

    static let standard = AppearanceSettings(transparency: 0.18, blur: 16)

    var clamped: AppearanceSettings {
        AppearanceSettings(
            transparency: min(max(transparency, 0), 0.8),
            blur: min(max(blur, 0), 40)
        )
    }
}

struct EffectiveAppearance: Equatable {
    let pageAlpha: Double
    let blurRadius: Int
}

struct SettingsStore {
    static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "pob/settings.json")
    }

    let fileURL: URL

    func load() -> AppearanceSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(AppearanceSettings.self, from: data)
        else { return .standard }
        return settings.clamped
    }

    func save(_ settings: AppearanceSettings) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(settings).write(to: fileURL, options: .atomic)
    }
}
