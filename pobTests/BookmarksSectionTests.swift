import AppKit
import Testing
@testable import pob

@Suite struct BookmarksSectionTests {
    let a = Bookmark(id: UUID(), title: "Aardvark", url: URL(string: "https://a.example/")!, folder: nil)
    let w1 = Bookmark(id: UUID(), title: "Payroll", url: URL(string: "https://w1.example/")!, folder: "Work")
    let w2 = Bookmark(id: UUID(), title: "Tickets", url: URL(string: "https://w2.example/")!, folder: "Work")
    let h = Bookmark(id: UUID(), title: "Recipes", url: URL(string: "https://h.example/")!, folder: "Home")

    private func showing(folders: [String] = [], bookmarks: [Bookmark], favicons: FaviconStore? = nil) -> BookmarksSection {
        let section = BookmarksSection(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
        section.favicons = favicons
        section.update(folders: folders, bookmarks: bookmarks)
        return section
    }
    private func loose(_ count: Int) -> [Bookmark] {
        (0..<count).map { Bookmark(id: UUID(), title: "Site \($0)", url: URL(string: "https://site\($0).example/")!, folder: nil) }
    }
    private func table(in section: BookmarksSection) throws -> NSTableView { try #require(section.subviewsDeep.compactMap { $0 as? NSTableView }.first) }
    private func scroll(in section: BookmarksSection) throws -> NSScrollView { try #require(section.subviewsDeep.compactMap { $0 as? NSScrollView }.first) }
    /// The row on show, or the one a reload would put there, because with no window nothing draws to bring it back.
    private func rowView(_ index: Int, in section: BookmarksSection) throws -> NSView {
        section.layoutSubtreeIfNeeded()
        return try #require(table(in: section).view(atColumn: 0, row: index, makeIfNecessary: true))
    }
    private func title(of row: NSView) -> String? { row.subviews.compactMap { $0 as? NSTextField }.first?.stringValue }
    private func icon(of row: NSView) -> NSImage? { row.subviews.compactMap { $0 as? NSImageView }.first?.image }
    /// On screen, far off to the side, because an animation's completion only fires in a window that's showing.
    private func inWindow(bookmarks: [Bookmark]) throws -> (NSWindow, BookmarksSection) {
        let window = offscreenWindow()
        let content = try #require(window.contentView)
        let section = showing(bookmarks: bookmarks)
        section.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(section)
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            section.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            section.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        return (window, section)
    }

    // MARK: Rows

    @Test func foldersComeFirstAndOpenOnesShowTheirBookmarks() {
        let rows = BookmarksSection.rows(folders: ["Work", "Home"], bookmarks: [a, w1, h, w2], openFolders: ["Work"])
        #expect(rows == [
            .folder("Work", isOpen: true), .bookmark(w1, inFolder: true), .bookmark(w2, inFolder: true),
            .folder("Home", isOpen: false), .bookmark(a, inFolder: false),
        ])
    }
    @Test func aBookmarkInAnUnlistedFolderStillShows() {
        let gone = Bookmark(id: UUID(), title: "Lost", url: URL(string: "https://gone.example/")!, folder: "Gone")
        #expect(BookmarksSection.rows(folders: [], bookmarks: [gone], openFolders: []) == [.bookmark(gone, inFolder: false)])
    }

    // MARK: Opening and closing

    @Test func theSectionStartsClosed() throws {
        let section = showing(folders: ["Work"], bookmarks: [a, w1])
        #expect(!section.isExpanded)
        #expect(try scroll(in: section).isHidden)
        #expect(section.listHeight.constant == 0)
        #expect(section.rows == [.folder("Work", isOpen: false), .bookmark(a, inFolder: false)])
    }
    @Test func theHeaderOpensAndClosesIt() throws {
        let section = showing(bookmarks: loose(2))
        let scroll = try scroll(in: section)
        section.toggleButton.performClick(nil)
        #expect(section.isExpanded)
        #expect(!scroll.isHidden)
        #expect(section.listHeight.constant == CGFloat(section.rows.count) * 30)
        #expect(section.listHeight.constant == 60)

        section.toggleButton.performClick(nil)
        #expect(!section.isExpanded)
        #expect(scroll.isHidden)
        #expect(section.listHeight.constant == 0)
    }
    @Test func manyBookmarksScrollInsteadOfGrowing() {
        let section = showing(bookmarks: loose(20))
        section.setExpanded(true, animated: false)
        #expect(BookmarksSection.maxListHeight == 210)
        #expect(section.listHeight.constant == BookmarksSection.maxListHeight)
    }
    /// The window keeps its size, and the list gives way to stay within its share.
    @Test func aShortWindowShrinksTheListInsteadOfGrowing() throws {
        let (window, section) = try inWindow(bookmarks: loose(30))
        defer { window.close() }
        window.setContentSize(NSSize(width: 300, height: 360))
        section.setExpanded(true, animated: false)
        window.layoutIfNeeded()
        #expect(try scroll(in: section).frame.height <= BookmarksSection.maxWindowShare * 360 + 0.5)
        #expect(try #require(window.contentView).frame.height == 360)
    }
    @Test func aTallWindowShowsSevenRows() throws {
        let (window, section) = try inWindow(bookmarks: loose(30))
        defer { window.close() }
        window.setContentSize(NSSize(width: 300, height: 1000))
        section.setExpanded(true, animated: false)
        window.layoutIfNeeded()
        #expect(try scroll(in: section).frame.height == BookmarksSection.maxListHeight)
        #expect(try #require(window.contentView).frame.height == 1000)
    }
    @Test func clickingAFolderOpensAndClosesIt() {
        let section = showing(folders: ["Work"], bookmarks: [w1])
        section.clickRow(0)
        #expect(section.rows == [.folder("Work", isOpen: true), .bookmark(w1, inFolder: true)])
        section.clickRow(0)
        #expect(section.rows == [.folder("Work", isOpen: false)])
    }
    @Test func clickingABookmarkOpensIt() {
        let section = showing(folders: ["Work"], bookmarks: [a, w1])
        var opened: [Bookmark] = []
        section.onOpen = { opened.append($0) }
        section.clickRow(1)
        section.clickRow(99)
        #expect(opened == [a])
    }
    @Test func aCommandClickOpensABookmarkInANewTab() {
        let section = showing(folders: ["Work"], bookmarks: [a, w1])
        var opened: [Bookmark] = []
        var inNewTab: [Bookmark] = []
        section.onOpen = { opened.append($0) }
        section.onOpenInNewTab = { inNewTab.append($0) }
        section.clickRow(1, modifiers: .command)
        #expect(inNewTab == [a])
        #expect(opened.isEmpty)

        section.clickRow(0, modifiers: .command) // a folder only opens
        #expect(section.rows.first == .folder("Work", isOpen: true))
        #expect(inNewTab == [a])
    }
    /// Through the table, so the ⌘ comes from the click itself.
    @Test(arguments: [false, true]) func aRealClickOnABookmarkHonoursCommand(command: Bool) throws {
        let (window, section) = try inWindow(bookmarks: [a])
        defer { window.close() }
        section.setExpanded(true, animated: false)
        window.contentView?.layoutSubtreeIfNeeded()
        let table = try table(in: section)
        let row = table.rect(ofRow: 0)
        let point = table.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: command ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        var opened: [Bookmark] = []
        var inNewTab: [Bookmark] = []
        section.onOpen = { opened.append($0) }
        section.onOpenInNewTab = { inNewTab.append($0) }
        window.postEvent(mouse(.leftMouseUp), atStart: false)
        table.mouseDown(with: mouse(.leftMouseDown))
        #expect(inNewTab == (command ? [a] : []))
        #expect(opened == (command ? [] : [a]))
    }
    @Test func aFolderThatGoesIsForgottenWhenItComesBack() {
        let section = showing(folders: ["Work"], bookmarks: [w1])
        section.clickRow(0)
        section.update(folders: [], bookmarks: [])
        section.update(folders: ["Work"], bookmarks: [w1])
        #expect(section.rows == [.folder("Work", isOpen: false)])
    }

    // MARK: Right-click

    @Test func aBookmarksMenuOffersRenameEditMoveAndDelete() throws {
        let section = showing(folders: ["Work"], bookmarks: [w1])
        section.clickRow(0)
        let menu = section.menu(forRow: 1)
        #expect(menu.items.map(\.title) == ["Rename…", "Edit Address…", "Move To", "", "Delete"])
        let move = try #require(menu.item(withTitle: "Move To")?.submenu)
        #expect(move.items.map(\.title) == ["No Folder", "", "Work"])
        #expect(move.item(withTitle: "Work")?.state == .on)
        #expect(move.item(withTitle: "No Folder")?.state == .off)
    }
    @Test func withNoFoldersThereIsNoMoveTo() {
        let section = showing(bookmarks: [a])
        #expect(section.menu(forRow: 0).items.map(\.title) == ["Rename…", "Edit Address…", "", "Delete"])
    }
    @Test func eachMenuItemReportsItsBookmark() throws {
        let section = showing(folders: ["Work"], bookmarks: [a]) // row 0 is the folder, row 1 the bookmark
        var deleted: UUID?
        var moves: [(id: UUID, folder: String?)] = []
        var renamed: (bookmark: Bookmark, anchor: NSView)?
        var readdressed: (bookmark: Bookmark, anchor: NSView)?
        section.onDelete = { deleted = $0 }
        section.onMove = { moves.append(($0, $1)) }
        section.onRename = { renamed = ($0, $1) }
        section.onEditAddress = { readdressed = ($0, $1) }

        // The menu stays with the row it was made for, even when the list changes while it's up.
        let menu = section.menu(forRow: 1)
        section.update(folders: ["Work"], bookmarks: [h, a])
        #expect(choose("Delete", in: menu))
        #expect(deleted == a.id)
        section.update(folders: ["Work"], bookmarks: [a])

        let move = try #require(section.menu(forRow: 1).item(withTitle: "Move To")?.submenu)
        #expect(choose("No Folder", in: move))
        #expect(choose("Work", in: move))
        #expect(moves.map(\.id) == [a.id, a.id])
        #expect(moves.map(\.folder) == [nil, "Work"])

        #expect(choose("Rename…", in: section.menu(forRow: 1)))
        #expect(renamed?.bookmark == a)
        #expect(renamed?.anchor != nil)
        #expect(choose("Edit Address…", in: section.menu(forRow: 1)))
        #expect(readdressed?.bookmark == a)
        #expect(readdressed?.anchor != nil)
    }
    @Test func aFoldersMenuOffersRenameAndDelete() {
        let section = showing(folders: ["Work"], bookmarks: [w1])
        var renamed: (name: String, anchor: NSView)?
        var deleted: String?
        section.onRenameFolder = { renamed = ($0, $1) }
        section.onDeleteFolder = { deleted = $0 }
        let menu = section.menu(forRow: 0)
        #expect(menu.items.map(\.title) == ["Rename Folder…", "", "Delete Folder"])

        #expect(choose("Rename Folder…", in: menu))
        #expect(renamed?.name == "Work")
        #expect(renamed?.anchor != nil)
        #expect(choose("Delete Folder", in: menu))
        #expect(deleted == "Work")
    }
    @Test func belowTheRowsThereIsNoMenu() {
        let section = showing(bookmarks: [a])
        #expect(section.menu(forRow: -1).items.isEmpty)
        #expect(section.menu(forRow: 50).items.isEmpty)
    }

    // MARK: Header buttons

    @Test func theHeaderButtonsReportThemselves() {
        let section = showing(bookmarks: [a])
        var added: NSView?
        var newFolder: NSView?
        section.onAdd = { added = $0 }
        section.onNewFolder = { newFolder = $0 }
        section.addButton.performClick(nil)
        section.newFolderButton.performClick(nil)
        #expect(added === section.addButton)
        #expect(newFolder === section.newFolderButton)
    }

    // MARK: Rebuilding only what changed

    /// Every change to any tab arrives here, and a reload would take the hover off whatever the pointer is on.
    @Test func anUpdateWithNothingNewKeepsTheRows() throws {
        let section = showing(folders: ["Work"], bookmarks: [a, w1])
        section.setExpanded(true, animated: false)
        let row = try rowView(0, in: section)
        section.update(folders: ["Work"], bookmarks: [a, w1])
        #expect(try rowView(0, in: section) === row)
    }
    @Test func aRenamedBookmarkShowsItsNewName() throws {
        var bookmark = a
        let section = showing(bookmarks: [bookmark])
        section.setExpanded(true, animated: false)
        let row = try rowView(0, in: section)
        #expect(title(of: row) == "Aardvark")

        bookmark.title = "Anteater"
        section.update(folders: [], bookmarks: [bookmark])
        let after = try rowView(0, in: section)
        #expect(after === row)
        #expect(title(of: after) == "Anteater")
    }
    /// The bookmark stays the same, so only the icon itself can say the row is out of date.
    @Test func aFaviconArrivingRefreshesItsRow() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let favicons = FaviconStore(directory: folder)
        let section = showing(bookmarks: [a], favicons: favicons)
        section.setExpanded(true, animated: false)
        let tile = icon(of: try rowView(0, in: section))
        #expect(tile != nil)
        #expect(favicons.image(forHost: "a.example") == nil)

        try writeIcon(forHost: "a.example", in: folder)
        section.update(folders: [], bookmarks: [a])
        let shown = icon(of: try rowView(0, in: section))
        #expect(shown === favicons.image(forHost: "a.example"))
        #expect(shown !== tile)
    }
    @Test func rowsReadOutTheirNames() throws {
        let section = showing(folders: ["Work"], bookmarks: [a, w1])
        section.setExpanded(true, animated: false)
        section.clickRow(0)
        section.layoutSubtreeIfNeeded()
        #expect(accessibleRows(of: try table(in: section)).map { $0.label } == ["Work", w1.title, a.title])
    }

    // MARK: Motion

    @Test func withMotionOnClosingHidesTheListOnlyOnceItsDown() async throws {
        let (window, section) = try inWindow(bookmarks: loose(2))
        defer { window.close() }
        let scroll = try scroll(in: section)
        withMotion(.smooth) {
            section.setExpanded(true, animated: true)
            section.setExpanded(false, animated: true)
            #expect(!scroll.isHidden)
        }
        #expect(await eventually { scroll.isHidden })
    }
    /// The close's completion still comes, cut short, and must leave the list to the open that followed.
    @Test func withMotionOpeningAgainMidCloseKeepsTheList() async throws {
        let (window, section) = try inWindow(bookmarks: loose(2))
        defer { window.close() }
        let scroll = try scroll(in: section)
        withMotion(.smooth) {
            section.setExpanded(true, animated: true)
            section.setExpanded(false, animated: true)
            section.setExpanded(true, animated: true)
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!scroll.isHidden)
        #expect(section.listHeight.constant == 60)
    }
}
