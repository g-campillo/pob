import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct BookmarkStoreTests {
    func file() -> JSONFile<BookmarkFile> {
        JSONFile(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json"))
    }
    let page = URL(string: "https://example.com/a")!

    @Test func togglingAddsThenRemoves() {
        let store = BookmarkStore(file: file())
        store.toggle(url: page, title: "A")
        #expect(store.contains(page))
        #expect(store.all.map(\.title) == ["A"])
        store.toggle(url: page, title: "A")
        #expect(!store.contains(page))
    }
    @Test func togglingReturnsWhatItAdded() throws {
        let store = BookmarkStore(file: file())
        let added = try #require(store.toggle(url: page, title: "A"))
        #expect(added.url == page && added.title == "A" && added.folder == nil)
        #expect(store.toggle(url: page, title: "A") == nil)
        #expect(store.all.isEmpty)
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
        #expect(file.load()?.bookmarks.count == 1)
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
    @Test func observersHearEveryChange() throws {
        let store = BookmarkStore(file: file())
        var heard = 0
        store.addObserver { heard += 1 }
        let id = try #require(store.toggle(url: page, title: "A")).id
        store.addFolder("F")
        store.move(id: id, to: "F")
        store.update(id: id, title: "B", url: page, folder: "F")
        store.renameFolder("F", to: "G")
        let other = store.add(title: "C", url: URL(string: "https://c.example/")!, folder: nil)
        store.remove(id: other.id)
        store.removeFolder("G")
        store.iconsChanged()
        #expect(heard == 9)
    }
    @Test func iconsChangedSavesNothing() {
        let file = file()
        let store = BookmarkStore(file: file)
        var heard = 0
        store.addObserver { heard += 1 }
        store.iconsChanged()
        #expect(heard == 1)
        #expect(!FileManager.default.fileExists(atPath: file.url.path()))
    }

    // MARK: Folders

    /// The shape of the live file: a bare list, pinned, with no folder key.
    @Test func aFileFromBeforeFoldersStillReads() throws {
        let file = file()
        try #"[{"id":"00000000-0000-0000-0000-000000000001","title":"Old","url":"https://old.example/","isPinned":true}]"#
            .write(to: file.url, atomically: true, encoding: .utf8)
        let store = BookmarkStore(file: file)
        #expect(store.all.map(\.title) == ["Old"])
        #expect(store.all.first?.folder == nil)
        #expect(store.folders.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.url.appendingPathExtension("unreadable").path()))

        store.add(title: "New", url: URL(string: "https://new.example/")!, folder: nil)
        #expect(try !String(contentsOf: file.url, encoding: .utf8).contains("isPinned"))
        #expect(BookmarkStore(file: file).all.map(\.title) == ["Old", "New"])
    }
    @Test func aFileFromBeforeFoldersListsItsFolders() throws {
        let file = file()
        try #"""
        [{"id":"00000000-0000-0000-0000-000000000001","title":"One","url":"https://one.example/","folder":"Bookmarks bar / Work","isPinned":false},
         {"id":"00000000-0000-0000-0000-000000000002","title":"Two","url":"https://two.example/","folder":"Bookmarks bar","isPinned":false},
         {"id":"00000000-0000-0000-0000-000000000003","title":"Three","url":"https://three.example/","folder":"Bookmarks bar / Work","isPinned":false}]
        """#.write(to: file.url, atomically: true, encoding: .utf8)
        #expect(BookmarkStore(file: file).folders == ["Bookmarks bar / Work", "Bookmarks bar"])
    }
    @Test func foldersAndBookmarksSurviveARelaunch() {
        let file = file()
        let store = BookmarkStore(file: file)
        store.addFolder("Empty")
        store.addFolder("Work")
        store.add(title: "A", url: page, folder: "Work")
        let relaunched = BookmarkStore(file: file)
        #expect(relaunched.folders == ["Empty", "Work"])
        #expect(relaunched.all.map(\.folder) == ["Work"])
        #expect(file.load()?.folders == ["Empty", "Work"])
    }
    @Test func addingToAFolderThatIsntListedListsIt() {
        let store = BookmarkStore(file: file())
        store.add(title: "A", url: page, folder: "New")
        #expect(store.folders == ["New"])
    }
    @Test func folderNamesAreTrimmedAndMustBeNewAndNotEmpty() {
        let store = BookmarkStore(file: file())
        #expect(store.addFolder("  Work ") == "Work")
        #expect(store.addFolder("Work") == nil)
        #expect(store.addFolder("   ") == nil)
        #expect(store.folders == ["Work"])
    }
    @Test func aRenamedFolderTakesItsBookmarks() {
        let store = BookmarkStore(file: file())
        let one = store.add(title: "One", url: URL(string: "https://one.example/")!, folder: "F")
        let two = store.add(title: "Two", url: URL(string: "https://two.example/")!, folder: "F")
        let loose = store.add(title: "Loose", url: URL(string: "https://loose.example/")!, folder: nil)
        #expect(store.renameFolder("F", to: " G ") == "G")
        #expect(store.all.filter { $0.folder == "G" }.map(\.id) == [one.id, two.id])
        #expect(store.all.first { $0.id == loose.id } == loose)
        #expect(store.folders == ["G"])
    }
    @Test func aRefusedRenameChangesNothing() {
        let store = BookmarkStore(file: file())
        store.add(title: "A", url: page, folder: "F")
        store.addFolder("G")
        let folders = store.folders
        let bookmarks = store.all
        var heard = 0
        store.addObserver { heard += 1 }
        #expect(store.renameFolder("F", to: "G") == nil)
        #expect(store.renameFolder("F", to: "  ") == nil)
        #expect(store.renameFolder("X", to: "Y") == nil)
        #expect(store.folders == folders && store.all == bookmarks)
        #expect(heard == 0)
        #expect(store.renameFolder("F", to: "F") == "F")
        #expect(store.folders == folders && store.all == bookmarks)
        #expect(heard == 0)
    }
    @Test func aFolderThatGoesTakesItsBookmarks() {
        let store = BookmarkStore(file: file())
        store.add(title: "In", url: URL(string: "https://in.example/")!, folder: "F")
        let loose = store.add(title: "Loose", url: URL(string: "https://loose.example/")!, folder: nil)
        store.removeFolder("F")
        #expect(store.folders.isEmpty)
        #expect(store.all == [loose])
        var heard = 0
        store.addObserver { heard += 1 }
        store.removeFolder("missing")
        #expect(heard == 0)
    }
    @Test func movingInAndOut() {
        let store = BookmarkStore(file: file())
        let bookmark = store.add(title: "A", url: page, folder: nil)
        store.move(id: bookmark.id, to: "F")
        #expect(store.all.first?.folder == "F")
        #expect(store.folders == ["F"])
        store.move(id: bookmark.id, to: nil)
        #expect(store.all.first?.folder == nil)
        #expect(store.folders == ["F"])
    }
    @Test func anUpdateWithNothingNewStaysQuiet() {
        let store = BookmarkStore(file: file())
        let bookmark = store.add(title: "A", url: page, folder: "F")
        var heard = 0
        store.addObserver { heard += 1 }
        store.update(id: bookmark.id, title: bookmark.title, url: bookmark.url, folder: bookmark.folder)
        store.move(id: bookmark.id, to: "F")
        #expect(heard == 0)
        store.update(id: UUID(), title: "B", url: URL(string: "https://b.example/")!, folder: "G")
        #expect(store.all == [bookmark])
        #expect(store.folders == ["F"])
        #expect(heard == 0)
    }
    @Test func importListsNewFoldersOnce() {
        let store = BookmarkStore(file: file())
        store.addFolder("A")
        store.importBookmarks([
            .init(title: "One", url: URL(string: "https://one.example/")!, folder: "B"),
            .init(title: "Two", url: URL(string: "https://two.example/")!, folder: "A"),
            .init(title: "Three", url: URL(string: "https://three.example/")!, folder: "B"),
        ])
        #expect(store.folders == ["A", "B"])
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
        controller.openBookmark(try #require(tabs.profile.bookmarks.all.first))
        #expect(tabs.list.records.count == 1)
        #expect(tabs.list.activeID == activeBefore)
        #expect(await eventually { controller.tab?.webView.url == target })
    }
    @Test func aBookmarkClickWithNoTabOpensOne() {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let model = AppearanceModel(store: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), reduceTransparency: false)
        let controller = WindowController(appearance: model, tabs: tabs)
        controller.openBookmark(Bookmark(id: UUID(), title: "Hi", url: URL(string: "data:text/html,hi")!, folder: nil))
        #expect(tabs.list.records.count == 1)
    }
    @Test func importSkipsWhatsThereAndSavesOnce() {
        let store = BookmarkStore(file: file())
        store.toggle(url: URL(string: "https://a.example/")!, title: "A")
        var heard = 0
        store.addObserver { heard += 1 }
        let b = BookmarkImport.Item(title: "B", url: URL(string: "https://b.example/")!, folder: "F")
        let added = store.importBookmarks([.init(title: "A again", url: URL(string: "https://a.example/")!, folder: nil), b, b])
        #expect(added == 1 && heard == 1)
        #expect(store.all.map(\.title) == ["A", "B"])
        #expect(store.all[1].folder == "F")
        #expect(store.folders == ["F"])
    }
    @Test func importingNothingNewStaysQuiet() {
        let store = BookmarkStore(file: file())
        var heard = 0
        store.addObserver { heard += 1 }
        #expect(store.importBookmarks([]) == 0 && heard == 0)
    }
}
