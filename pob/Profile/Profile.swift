import Foundation
import WebKit

/// Everything one profile owns, shared by all its windows.
final class Profile {
    let id: UUID
    let directory: URL
    let isPersistent: Bool
    /// The profile a private one was opened from. nil for every other profile.
    let parent: Profile?
    var isPrivate: Bool { parent != nil }
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
    lazy var contentBlocker: ContentBlocker = usesSharedRules ? .shared : ContentBlocker(
        cacheDirectory: directory.appending(path: "rules", directoryHint: .isDirectory),
        bundledDirectory: Bundle.main.resourceURL ?? directory,
        fetch: { try await ContentBlocker.download($0) }
    )

    /// In memory only: AppController (Task 2) fills it and saves it with the session.
    var parked: WindowSnapshot?

    /// Persistent profiles share one set of rules. A temporary one keeps its own, so a test never touches the real cache.
    var usesSharedRules: Bool { isPersistent }

    private let faviconDirectory: URL
    private let downloadsDirectory: URL

    /// Built ahead of time, so a new tab doesn't wait for a web view.
    private(set) var spareTab: Tab?

    static let initialID = UUID(uuidString: "6F0B5C2E-2F4B-4C6E-9B52-1F6B0A5D7C11")!

    static let initial = makePersistent(id: initialID)

    private static var persistentProfiles: [UUID: Profile] = [:]

    /// One instance per id, so every window of a profile shares its stores.
    static func persistent(id: UUID) -> Profile {
        if id == initialID { return initial }
        if let profile = persistentProfiles[id] { return profile }
        let profile = makePersistent(id: id)
        persistentProfiles[id] = profile
        return profile
    }

    static func forget(id: UUID) {
        persistentProfiles[id] = nil
    }

    private static func makePersistent(id: UUID) -> Profile {
        Profile(
            id: id,
            directory: URL.applicationSupportDirectory.appending(path: "pob/profiles/\(id.uuidString)", directoryHint: .isDirectory),
            isPersistent: true,
            faviconDirectory: URL.applicationSupportDirectory.appending(path: "pob/favicons", directoryHint: .isDirectory),
            downloadsDirectory: URL.downloadsDirectory
        )
    }

    /// Private data store and a unique temp folder, for tests. A test that lists it passes the id it's listed under.
    static func temporary(id: UUID = UUID()) -> Profile {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pob-\(UUID().uuidString)", directoryHint: .isDirectory)
        return Profile(id: id, directory: directory, isPersistent: false, faviconDirectory: directory.appending(path: "favicons", directoryHint: .isDirectory), downloadsDirectory: directory.appending(path: "Downloads", directoryHint: .isDirectory))
    }

    /// Cookies in memory and a temporary folder that goes with its last window. It reads its parent's bookmarks, icons,
    /// rules and downloads folder, and writes no history or icons. A private profile passed in hands over its own parent.
    static func makePrivate(from parent: Profile) -> Profile {
        let parent = parent.parent ?? parent
        let id = UUID()
        let profile = Profile(
            id: id,
            directory: FileManager.default.temporaryDirectory.appending(path: "pob-private-\(id.uuidString)", directoryHint: .isDirectory),
            isPersistent: false,
            faviconDirectory: parent.faviconDirectory,
            downloadsDirectory: parent.downloadsDirectory,
            parent: parent
        )
        profile.bookmarks = parent.bookmarks
        profile.favicons = parent.favicons
        profile.contentBlocker = parent.contentBlocker
        return profile
    }

    private init(id: UUID, directory: URL, isPersistent: Bool, faviconDirectory: URL, downloadsDirectory: URL, parent: Profile? = nil) {
        self.faviconDirectory = faviconDirectory
        self.downloadsDirectory = downloadsDirectory
        self.id = id
        self.directory = directory
        self.isPersistent = isPersistent
        self.parent = parent
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
