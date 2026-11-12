import Foundation
import OSLog

struct Bookmark: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var url: URL
    /// The folder's name, or nil for a bookmark in no folder. An imported folder inside another is named with both,
    /// joined with " / ". Files from before folders also have `isPinned`, which reading ignores.
    var folder: String?
}

/// What `bookmarks.json` holds. Folders are listed apart from the bookmarks, so an empty one is kept.
struct BookmarkFile: Codable, Equatable {
    var folders: [String]
    var bookmarks: [Bookmark]

    init(folders: [String], bookmarks: [Bookmark]) {
        self.folders = folders
        self.bookmarks = bookmarks
    }

    /// A file from before folders is a bare list of bookmarks, and still reads. The store lists its folders from the bookmarks.
    init(from decoder: any Decoder) throws {
        if let bookmarks = try? decoder.singleValueContainer().decode([Bookmark].self) {
            self.init(folders: [], bookmarks: bookmarks)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            folders: try container.decode([String].self, forKey: .folders),
            bookmarks: try container.decode([Bookmark].self, forKey: .bookmarks)
        )
    }
}

/// A profile's bookmarks and folders, shared by all its windows. Windows listen through `addObserver`.
final class BookmarkStore {
    private let file: JSONFile<BookmarkFile>
    private var observers: [() -> Void] = []
    private(set) var all: [Bookmark]
    /// In the order the rail lists them. Every bookmark's folder is one of these, and a folder stays when it's emptied.
    private(set) var folders: [String]

    init(file: JSONFile<BookmarkFile>) {
        self.file = file
        let saved = file.load()
        let bookmarks = saved?.bookmarks ?? []
        all = bookmarks
        // A file from before folders lists none, and a folder a bookmark names must never be missing.
        folders = Self.adding((saved?.folders ?? []) + bookmarks.compactMap(\.folder), to: [])
    }

    func addObserver(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }

    func contains(_ url: URL) -> Bool { all.contains { $0.url == url } }

    /// ⌘D. A new bookmark goes in no folder. Returns it, or nil when the address was saved and is now gone.
    @discardableResult
    func toggle(url: URL, title: String) -> Bookmark? {
        guard !contains(url) else {
            all.removeAll { $0.url == url }
            changed()
            return nil
        }
        return add(title: title, url: url, folder: nil)
    }

    /// A folder that isn't listed yet is added, so a bookmark never names a folder that isn't there.
    @discardableResult
    func add(title: String, url: URL, folder: String?) -> Bookmark {
        let bookmark = Bookmark(id: UUID(), title: title, url: url, folder: folder)
        all.append(bookmark)
        folders = Self.adding(folder.map { [$0] } ?? [], to: folders)
        changed()
        return bookmark
    }

    /// Says nothing when nothing differs.
    func update(id: UUID, title: String, url: URL, folder: String?) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        let updated = Bookmark(id: id, title: title, url: url, folder: folder)
        guard all[index] != updated else { return }
        all[index] = updated
        folders = Self.adding(folder.map { [$0] } ?? [], to: folders)
        changed()
    }

    /// nil takes it out of every folder.
    func move(id: UUID, to folder: String?) {
        guard let bookmark = all.first(where: { $0.id == id }) else { return }
        update(id: id, title: bookmark.title, url: bookmark.url, folder: folder)
    }

    func remove(id: UUID) {
        all.removeAll { $0.id == id }
        changed()
    }

    /// Skips addresses already saved, saves once and tells the observers once. Returns how many were added.
    @discardableResult
    func importBookmarks(_ items: [BookmarkImport.Item]) -> Int {
        var known = Set(all.map(\.url))
        let fresh = items.filter { known.insert($0.url).inserted }
        guard !fresh.isEmpty else { return 0 }
        all += fresh.map { Bookmark(id: UUID(), title: $0.title, url: $0.url, folder: $0.folder) }
        folders = Self.adding(fresh.compactMap(\.folder), to: folders)
        changed()
        return fresh.count
    }

    /// Returns the name it took, trimmed, or nil for an empty name or one already taken.
    @discardableResult
    func addFolder(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !folders.contains(name) else { return nil }
        folders.append(name)
        changed()
        return name
    }

    /// Its bookmarks follow it. Returns the name it took, trimmed, or nil when the new name is empty or another folder's.
    /// The same name again changes nothing and still counts.
    @discardableResult
    func renameFolder(_ name: String, to newName: String) -> String? {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = folders.firstIndex(of: name), !newName.isEmpty else { return nil }
        guard newName != name else { return name }
        guard !folders.contains(newName) else { return nil }
        folders[index] = newName
        for bookmark in all.indices where all[bookmark].folder == name {
            all[bookmark].folder = newName
        }
        changed()
        return newName
    }

    /// Its bookmarks go with it.
    func removeFolder(_ name: String) {
        guard folders.contains(name) else { return }
        folders.removeAll { $0 == name }
        all.removeAll { $0.folder == name }
        changed()
    }

    /// An icon arrived. Nothing saved changes, but every window's rail shows it.
    func iconsChanged() {
        observers.forEach { $0() }
    }

    private func changed() {
        do { try file.save(BookmarkFile(folders: folders, bookmarks: all)) } catch {
            Logger(subsystem: "pob", category: "BookmarkStore").error("Saving bookmarks failed: \(error)")
        }
        observers.forEach { $0() }
    }

    /// The names not already in `list`, appended in the order they first appear.
    private static func adding(_ names: [String], to list: [String]) -> [String] {
        var seen = Set(list)
        return list + names.filter { seen.insert($0).inserted }
    }
}
