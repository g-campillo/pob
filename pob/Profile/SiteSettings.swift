import Foundation
import OSLog

struct SiteSetting: Codable, Equatable {
    var zoom: Double?
    var camera: Bool?
    var microphone: Bool?
    var location: Bool?
    var allowsInvalidCertificate: Bool?
}

final class SiteSettings {
    private let file: JSONFile<[String: SiteSetting]>
    private var values: [String: SiteSetting]

    init(file: JSONFile<[String: SiteSetting]>) {
        self.file = file
        values = file.load() ?? [:]
    }

    subscript(host: String) -> SiteSetting {
        get { values[host] ?? SiteSetting() }
        set {
            values[host] = newValue
            do { try file.save(values) } catch {
                Logger(subsystem: "pob", category: "SiteSettings").error("Saving site settings failed: \(error)")
            }
        }
    }
}
