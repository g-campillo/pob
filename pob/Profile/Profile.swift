import Foundation
import WebKit

/// Everything one profile owns, shared by all its windows.
final class Profile {
    let id: UUID
    let directory: URL
    let isPersistent: Bool
    /// Built on first use, because building it makes folders in the store, and a test reading `Profile.initial` mustn't.
    lazy var dataStore: WKWebsiteDataStore = isPersistent ? WKWebsiteDataStore(forIdentifier: id) : .nonPersistent()

    lazy var siteSettings = SiteSettings(file: JSONFile(url: directory.appending(path: "sites.json")))

    lazy var history = HistoryStore(file: directory.appending(path: "history.sqlite"))

    lazy var bookmarks = BookmarkStore(file: JSONFile(url: directory.appending(path: "bookmarks.json")))

    lazy var favicons = FaviconStore(directory: faviconDirectory)

    lazy var session = SessionStore(file: JSONFile(url: directory.appending(path: "session.json")))

    /// Shared by every window. A temporary profile keeps its downloads in its own folder.
    lazy var downloads = Downloads(directory: downloadsDirectory)

    /// Built with the first tab. A test sets its own, for small lists and no network.
    lazy var contentBlocker = ContentBlocker(
        cacheDirectory: directory.appending(path: "rules", directoryHint: .isDirectory),
        bundledDirectory: Bundle.main.resourceURL ?? directory,
        fetch: { try await ContentBlocker.download($0) }
    )

    private let faviconDirectory: URL
    private let downloadsDirectory: URL

    /// Built ahead of time, so a new tab doesn't wait for a web view.
    private(set) var spareTab: Tab?

    static let initial = Profile(
        id: UUID(uuidString: "6F0B5C2E-2F4B-4C6E-9B52-1F6B0A5D7C11")!,
        directory: URL.applicationSupportDirectory.appending(path: "pob/profiles/6F0B5C2E-2F4B-4C6E-9B52-1F6B0A5D7C11", directoryHint: .isDirectory),
        isPersistent: true,
        faviconDirectory: URL.applicationSupportDirectory.appending(path: "pob/favicons", directoryHint: .isDirectory),
        downloadsDirectory: URL.downloadsDirectory
    )

    /// Private data store and a unique temp folder, for tests.
    static func temporary() -> Profile {
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appending(path: "pob-\(id.uuidString)", directoryHint: .isDirectory)
        return Profile(id: id, directory: directory, isPersistent: false, faviconDirectory: directory.appending(path: "favicons", directoryHint: .isDirectory), downloadsDirectory: directory.appending(path: "Downloads", directoryHint: .isDirectory))
    }

    private init(id: UUID, directory: URL, isPersistent: Bool, faviconDirectory: URL, downloadsDirectory: URL) {
        self.faviconDirectory = faviconDirectory
        self.downloadsDirectory = downloadsDirectory
        self.id = id
        self.directory = directory
        self.isPersistent = isPersistent
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
