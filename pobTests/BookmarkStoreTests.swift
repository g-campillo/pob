import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct BookmarkStoreTests {
    func file() -> JSONFile<[Bookmark]> {
        JSONFile(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json"))
    }
    let page = URL(string: "https://example.com/a")!

    @Test func togglingAddsThenRemoves() {
        let store = BookmarkStore(file: file())
        store.toggle(url: page, title: "A")
        #expect(store.contains(page))
        #expect(store.pinned.map(\.title) == ["A"])
        store.toggle(url: page, title: "A")
        #expect(!store.contains(page))
    }
    @Test func unpinningKeepsTheBookmark() {
        let store = BookmarkStore(file: file())
        store.toggle(url: page, title: "A")
        store.setPinned(false, id: store.all[0].id)
        #expect(store.pinned.isEmpty)
        #expect(store.contains(page))
    }
    @Test func bookmarksSurviveARelaunch() {
        let file = file()
        BookmarkStore(file: file).toggle(url: page, title: "A")
        #expect(BookmarkStore(file: file).contains(page))
    }
    @Test func corruptFilesStartEmpty() throws {
        let file = file()
        try "nope".write(to: file.url, atomically: true, encoding: .utf8)
        #expect(BookmarkStore(file: file).all.isEmpty)
    }
    /// The next ⌘D rewrites the file, so without a copy one typo would cost every bookmark.
    @Test func aCorruptFileIsKeptBeforeTheNextBookmarkReplacesIt() throws {
        let file = file()
        try "nope".write(to: file.url, atomically: true, encoding: .utf8)
        let store = BookmarkStore(file: file)
        store.toggle(url: page, title: "A")
        #expect(file.load()?.count == 1)
        #expect(try String(contentsOf: file.url.appendingPathExtension("unreadable"), encoding: .utf8) == "nope")
    }
    @Test func letterTilesUseTheHostsFirstLetter() {
        #expect(FaviconStore.letter(for: "www.example.com") == "E")
        #expect(FaviconStore.letter(for: "") == "?")
    }
    @Test func commandIsBound() {
        let command = CommandList.standard { _ in }.command(.bookmarkPage)
        #expect(command?.key == "d")
        #expect(command?.isReserved == false)
    }
    @Test func observersHearEveryChange() {
        let store = BookmarkStore(file: file())
        var heard = 0
        store.addObserver { heard += 1 }
        store.toggle(url: page, title: "A")
        store.setPinned(false, id: store.all[0].id)
        store.remove(id: store.all[0].id)
        #expect(heard == 3)
    }

    // MARK: Favicons

    @Test func iconAddressesFromThePageAreLimitedToWebAndData() {
        let pageURL = URL(string: "https://example.com/a/b")
        #expect(FaviconStore.iconURL(declared: "/i.png", page: pageURL)?.absoluteString == "https://example.com/i.png")
        #expect(FaviconStore.iconURL(declared: "data:image/png;base64,AAAA", page: pageURL)?.scheme == "data")
        for refused in ["file:///etc/passwd", "ftp://example.com/i.png", "javascript:alert(1)"] {
            #expect(FaviconStore.iconURL(declared: refused, page: pageURL)?.absoluteString == "https://example.com/favicon.ico", "\(refused)")
        }
        #expect(FaviconStore.iconURL(declared: nil, page: pageURL)?.absoluteString == "https://example.com/favicon.ico")
        #expect(FaviconStore.iconURL(declared: nil, page: URL(string: "file:///tmp/x.html")) == nil)
    }
    @Test func aFileIconIsNeverRead() async throws {
        let png = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".png")
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { _ in NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); return true }
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(rep.representation(using: .png, properties: [:])).write(to: png)
        let tab = await tabWith(html: #"<link rel="icon" href="\#(png.absoluteString)">"#)
        let store = FaviconStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        await store.update(host: "localhost", from: tab.webView)
        #expect(store.image(forHost: "localhost") == nil)
    }
    @Test func cacheNamesCannotEscapeTheFolder() {
        for host in ["../../etc/passwd", "a/b", "..", "", "x\u{0}y", "evil.com/../../z"] {
            let name = FaviconStore.fileName(forHost: host)
            #expect(!name.contains("/"), "\(host)")
            let url = URL(filePath: "/cache/favicons").appending(path: name, directoryHint: .notDirectory)
            #expect(url.deletingLastPathComponent().path == "/cache/favicons", "\(host)")
        }
    }
    @Test func aBookmarkClickOpensInTheCurrentTab() async throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let model = AppearanceModel(store: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), reduceTransparency: false)
        let controller = WindowController(appearance: model, tabs: tabs)
        let target = URL(string: "data:text/html,hi")!
        tabs.profile.bookmarks.toggle(url: target, title: "Hi")
        #expect(!controller.rail.pinned.isHidden)
        let activeBefore = tabs.list.activeID
        controller.openBookmark(try #require(tabs.profile.bookmarks.pinned.first))
        #expect(tabs.list.records.count == 1)
        #expect(tabs.list.activeID == activeBefore)
        #expect(await eventually { controller.tab?.webView.url == target })
    }
    @Test func aBookmarkClickWithNoTabOpensOne() {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let model = AppearanceModel(store: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), reduceTransparency: false)
        let controller = WindowController(appearance: model, tabs: tabs)
        controller.openBookmark(Bookmark(id: UUID(), title: "Hi", url: URL(string: "data:text/html,hi")!, folder: nil, isPinned: true))
        #expect(tabs.list.records.count == 1)
    }
}
