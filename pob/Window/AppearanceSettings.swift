import Foundation

struct AppearanceSettings: Codable, Equatable {
    var transparency: Double
    var blur: Int
    /// nil means Google. Optional so a Stage 2 file, which has no engine, still decodes.
    var searchEngine: SearchEngine? = nil

    static let standard = AppearanceSettings(transparency: 0.18, blur: 16)

    var clamped: AppearanceSettings {
        var clamped = self
        clamped.transparency = min(max(transparency, 0), 0.8)
        clamped.blur = min(max(blur, 0), 40)
        return clamped
    }
}

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case google, duckDuckGo, bing

    var id: Self { self }

    var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        }
    }

    /// `AddressInput` has already percent-encoded the query.
    func url(for query: String) -> URL {
        let base = switch self {
        case .google: "https://www.google.com/search?q="
        case .duckDuckGo: "https://duckduckgo.com/?q="
        case .bing: "https://www.bing.com/search?q="
        }
        return URL(string: base + query)!
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

    private var file: JSONFile<AppearanceSettings> { JSONFile(url: fileURL) }

    func load() -> AppearanceSettings {
        file.load()?.clamped ?? .standard
    }

    func save(_ settings: AppearanceSettings) throws {
        try file.save(settings)
    }
}
