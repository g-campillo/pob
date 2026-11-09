import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct BookmarkImportTests {
    static let chrome = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
        <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
        <DL><p>
            <DT><A HREF="https://example.com/" ADD_DATE="1" ICON="data:image/png;base64,AAAA">Example</A>
            <DT><H3 ADD_DATE="1">Work</H3>
            <DL><p>
                <DT><A HREF="https://rd.example/">R&amp;D &lt;team&gt;</A>
            </DL><p>
        </DL><p>
        <DT><A HREF="https://loose.example/">Loose</A>
    </DL><p>
    """
    static let safari = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <HTML><META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8"><Title>Bookmarks</Title><H1>Bookmarks</H1>
    <DT><H3 FOLDED>Favorites</H3>
    <DL><p>
    <DT><A HREF="https://apple.com/">Apple</A>
    </DL><p>
    <DT><H3 id="com.apple.ReadingList">Reading List</H3>
    <DL><p>
    <DT><A HREF="http://later.example/read">Later &#39;s</A>
    </DL><p>
    </HTML>
    """

    @Test func readsAChromeExport() {
        #expect(BookmarkImport.parse(Self.chrome) == [
            .init(title: "Example", url: URL(string: "https://example.com/")!, folder: "Bookmarks bar"),
            .init(title: "R&D <team>", url: URL(string: "https://rd.example/")!, folder: "Bookmarks bar / Work"),
            .init(title: "Loose", url: URL(string: "https://loose.example/")!, folder: nil),
        ])
    }
    @Test func readsASafariExport() {
        #expect(BookmarkImport.parse(Self.safari).map(\.folder) == ["Favorites", "Reading List"])
        #expect(BookmarkImport.parse(Self.safari).last?.title == "Later 's")
    }
    @Test func skipsAddressesThatArentWebPages() {
        let html = ["javascript:alert(1)", "place:sort=8", "data:text/html,x", "file:///etc/hosts", "about:blank", "not a url"]
            .map { "<DT><A HREF=\"\($0)\">x</A>" }.joined(separator: "\n")
        #expect(BookmarkImport.parse(html).isEmpty)
    }
    @Test func anEmptyTitleBecomesTheHost() {
        #expect(BookmarkImport.parse(#"<DT><A HREF="https://x.example/a"><b></b></A>"#).first?.title == "x.example")
    }
    @Test func lowercaseTagsAndExtraAttributesWork() {
        #expect(BookmarkImport.parse(#"<dt><a add_date="1" href="https://y.example/" tags="t">Y</a>"#).first?.url == URL(string: "https://y.example/"))
    }
    @Test func aLargeExportReadsEveryBookmark() {
        let html = (0..<5_000).map { "<DT><A HREF=\"https://e\($0).example/\">E\($0)</A>" }.joined(separator: "\n")
        #expect(BookmarkImport.parse(html).count == 5_000)
    }
    @Test func brokenMarkupNeitherCrashesNorHangs() {
        // About 1 MB of tags that never close, so a scan that backtracks per tag would take minutes.
        let junk = String(repeating: "<a href=\"https://z.example/ <h3 x <dl ", count: 25_000) + String(repeating: "</dl><h3>", count: 1_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure { #expect(BookmarkImport.parse(junk).isEmpty) }
        #expect(elapsed < .seconds(1))
        #expect(BookmarkImport.parse("<a href=https://u.example/ >U</a><dl></dl></dl><a data-href='https://no.example/' href='https://q.example/'>&#x41;&#9999999999;</a>").map(\.title) == ["U", "A&#9999999999;"])
    }
    @Test func aHugeIconAttributeDoesntDropTheBookmark() {
        let icon = String(repeating: "A", count: 100_000)
        let items = BookmarkImport.parse("<DT><A HREF=\"https://big.example/\" ICON=\"data:image/png;base64,\(icon)\">Big</A>")
        #expect(items.map(\.title) == ["Big"])
    }

    // MARK: The command

    func window() -> WindowController {
        let model = AppearanceModel(store: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")), reduceTransparency: false)
        return WindowController(appearance: model, tabs: TabManager(profile: .temporary(), keepsSpare: false))
    }
    func file(_ html: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func notice(_ controller: WindowController) -> String? {
        func find(_ view: NSView) -> String? {
            if let field = view as? NSTextField { return field.stringValue }
            return view.subviews.lazy.compactMap(find).first
        }
        return controller.pill.isHidden ? nil : find(controller.pill)
    }
    func run(_ controller: WindowController, choosing url: URL?) async {
        controller.chooseImportFile = { _ in url }
        controller.perform(.importBookmarks)
        await controller.importTask?.value
    }

    @Test func theCommandImportsIntoThisWindowsProfile() async throws {
        let controller = window()
        await run(controller, choosing: try file(Self.chrome))
        #expect(controller.tabs.profile.bookmarks.all.count == 3)
        #expect(notice(controller) == "Imported 3 bookmarks")
    }
    @Test func cancellingThePanelChangesNothing() async {
        let controller = window()
        await run(controller, choosing: nil)
        #expect(controller.tabs.profile.bookmarks.all.isEmpty)
        #expect(controller.pill.isHidden)
    }
    @Test func aFileWithNoBookmarksSaysSo() async throws {
        let controller = window()
        await run(controller, choosing: try file("<html><body>Hello</body></html>"))
        #expect(notice(controller) == "No bookmarks found")
        let again = try file(Self.chrome)
        await run(controller, choosing: again)
        await run(controller, choosing: again)
        #expect(notice(controller) == "No new bookmarks")
    }
    @Test func aSingleBookmarkIsSingular() async throws {
        let controller = window()
        await run(controller, choosing: try file(#"<DT><A HREF="https://one.example/">One</A>"#))
        #expect(notice(controller) == "Imported 1 bookmark")
    }
}
