import Foundation
import OSLog

struct ProfileInfo: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
}

/// Which profiles exist. Windows listen through `addObserver`.
final class ProfileList {
    static var defaultFileURL: URL { URL.applicationSupportDirectory.appending(path: "pob/profiles.json") }

    private static let maxNameLength = 40

    private let file: JSONFile<[ProfileInfo]>
    private var observers: [() -> Void] = []
    /// Never empty.
    private(set) var all: [ProfileInfo]

    init(file: JSONFile<[ProfileInfo]>) {
        self.file = file
        let loaded = file.load() ?? []
        all = loaded.isEmpty ? [ProfileInfo(id: Profile.initialID, name: "Main")] : loaded
    }

    func addObserver(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }

    @discardableResult func add(name: String) -> ProfileInfo {
        let info = ProfileInfo(id: UUID(), name: Self.clean(name) ?? "Profile \(all.count + 1)")
        all.append(info)
        changed()
        return info
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = all.firstIndex(where: { $0.id == id }), let name = Self.clean(name) else { return }
        all[index].name = name
        changed()
    }

    func remove(_ id: UUID) {
        guard all.count > 1, all.contains(where: { $0.id == id }) else { return }
        all.removeAll { $0.id == id }
        changed()
    }

    func name(of id: UUID) -> String? { all.first { $0.id == id }?.name }

    /// nil when nothing is left of it.
    private static func clean(_ name: String) -> String? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
        return trimmed.isEmpty ? nil : trimmed
    }

    private func changed() {
        do { try file.save(all) } catch {
            Logger(subsystem: "pob", category: "ProfileList").error("Saving the profiles failed: \(error)")
        }
        observers.forEach { $0() }
    }
}
