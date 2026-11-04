import Foundation
import WebKit

/// Everything one profile owns, shared by all its windows.
final class Profile {
    let id: UUID
    let directory: URL
    let isPersistent: Bool
    let dataStore: WKWebsiteDataStore

    lazy var siteSettings = SiteSettings(file: JSONFile(url: directory.appending(path: "sites.json")))

    lazy var history = HistoryStore(file: directory.appending(path: "history.sqlite"))

    lazy var bookmarks = BookmarkStore(file: JSONFile(url: directory.appending(path: "bookmarks.json")))

    lazy var favicons = FaviconStore(directory: faviconDirectory)

    lazy var session = SessionStore(file: JSONFile(url: directory.appending(path: "session.json")))

    private let faviconDirectory: URL

    /// Built ahead of time, so a new tab doesn't wait for a web view.
    private(set) var spareTab: Tab?

    static let initial = Profile(
        id: UUID(uuidString: "6F0B5C2E-2F4B-4C6E-9B52-1F6B0A5D7C11")!,
        directory: URL.applicationSupportDirectory.appending(path: "pob/profiles/6F0B5C2E-2F4B-4C6E-9B52-1F6B0A5D7C11", directoryHint: .isDirectory),
        isPersistent: true,
        faviconDirectory: URL.applicationSupportDirectory.appending(path: "pob/favicons", directoryHint: .isDirectory)
    )

    /// Private data store and a unique temp folder, for tests.
    static func temporary() -> Profile {
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appending(path: "pob-\(id.uuidString)", directoryHint: .isDirectory)
        return Profile(id: id, directory: directory, isPersistent: false, faviconDirectory: directory.appending(path: "favicons", directoryHint: .isDirectory))
    }

    private init(id: UUID, directory: URL, isPersistent: Bool, faviconDirectory: URL) {
        self.faviconDirectory = faviconDirectory
        self.id = id
        self.directory = directory
        self.isPersistent = isPersistent
        dataStore = isPersistent ? WKWebsiteDataStore(forIdentifier: id) : .nonPersistent()
    }

    func prepareSpareTab() {
        if spareTab == nil {
            spareTab = Tab(profile: self)
        }
    }

    func takeSpareTab() -> Tab {
        defer { spareTab = nil }
        return spareTab ?? Tab(profile: self)
    }
}
