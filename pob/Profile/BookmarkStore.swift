import Foundation
import OSLog

struct Bookmark: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var url: URL
    var folder: String?
    var isPinned: Bool
}

/// A profile's bookmarks, shared by all its windows. Windows listen through `addObserver`.
final class BookmarkStore {
    private let file: JSONFile<[Bookmark]>
    private var observers: [() -> Void] = []
    private(set) var all: [Bookmark]

    init(file: JSONFile<[Bookmark]>) {
        self.file = file
        all = file.load() ?? []
    }

    var pinned: [Bookmark] { all.filter(\.isPinned) }

    func addObserver(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }

    func contains(_ url: URL) -> Bool { all.contains { $0.url == url } }

    /// A new bookmark starts pinned, so the shortcut visibly does something.
    func toggle(url: URL, title: String) {
        if contains(url) {
            all.removeAll { $0.url == url }
        } else {
            all.append(Bookmark(id: UUID(), title: title, url: url, folder: nil, isPinned: true))
        }
        changed()
    }

    func setPinned(_ isPinned: Bool, id: UUID) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].isPinned = isPinned
        changed()
    }

    func remove(id: UUID) {
        all.removeAll { $0.id == id }
        changed()
    }

    private func changed() {
        do { try file.save(all) } catch {
            Logger(subsystem: "pob", category: "BookmarkStore").error("Saving bookmarks failed: \(error)")
        }
        observers.forEach { $0() }
    }
}
