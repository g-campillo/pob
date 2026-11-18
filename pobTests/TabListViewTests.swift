import AppKit
import Testing
@testable import pob

@Suite struct TabListViewTests {
    @Test func showsOneRowPerTab() {
        let view = TabListView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
        view.update(records: [TabRecord(title: "One"), TabRecord(title: "Two")], activeID: nil)
        #expect(view.rowCount == 2)
    }
    @Test func clickingARowReportsItsTab() {
        let view = TabListView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
        let records = [TabRecord(title: "One"), TabRecord(title: "Two")]
        view.update(records: records, activeID: records[0].id)
        var selected: UUID?
        view.onSelect = { selected = $0 }
        view.selectRow(1)
        #expect(selected == records[1].id)
    }
    @Test func untitledTabsFallBackToTheirHost() {
        #expect(TabListView.displayTitle(for: TabRecord(url: URL(string: "https://example.com/a"))) == "example.com")
        #expect(TabListView.displayTitle(for: TabRecord()) == "New Tab")
    }
    @Test func theRailListsTheWindowsTabs() {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        tabs.newTab(nil, activate: true)
        let model = AppearanceModel(store: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), reduceTransparency: false)
        let controller = WindowController(appearance: model, tabs: tabs)
        #expect(controller.rail.tabList.rowCount == 2)
    }
    @Test func recordsFollowTheirTabs() async {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.webView.loadHTMLString("<title>Hello</title>", baseURL: URL(string: "https://localhost/")) }
        #expect(await eventually { tabs.list.active?.title == "Hello" })
        #expect(tabs.list.active?.url?.host() == "localhost")
    }

    @Test func dropsFromAnotherWindowAreRefused() {
        let view = TabListView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
        let ours = NSTableView()
        let theirs = NSTableView()
        #expect(view.tableView(ours, validateDrop: FakeDrag(source: theirs), proposedRow: 0, proposedDropOperation: .above) == [])
        #expect(view.tableView(ours, validateDrop: FakeDrag(source: ours), proposedRow: 0, proposedDropOperation: .above) == .move)
    }

    // MARK: Rebuilding only what changed

    private func table(in view: NSView) throws -> NSTableView { try #require(view.subviewsDeep.compactMap { $0 as? NSTableView }.first) }
    /// The row on show, or the one a reload would put there, because with no window nothing draws to bring it back.
    private func rowViews(in view: TabListView) throws -> [NSView] {
        view.layoutSubtreeIfNeeded()
        let table = try table(in: view)
        return (0..<table.numberOfRows).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: true) }
    }
    private func title(of row: NSView) -> String? { row.subviews.compactMap { $0 as? NSTextField }.first?.stringValue }
    private func closeButton(of row: NSView) -> NSButton? { row.subviews.compactMap { $0 as? NSButton }.first }
    private func icon(of row: NSView) -> NSImage? { row.subviews.compactMap { $0 as? NSImageView }.first?.image }
    private func hasFill(_ row: NSView) -> Bool { row.subviews.contains { $0 is ActiveFill && !$0.isHidden } }
    private func listShowing(_ records: [TabRecord], active: UUID?, favicons: FaviconStore? = nil) -> TabListView {
        let view = TabListView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
        view.favicons = favicons
        view.update(records: records, activeID: active)
        view.layoutSubtreeIfNeeded() // puts real rows up, so an update has them to touch
        return view
    }

    @Test func theActiveRowsFillHasRoundedCorners() throws {
        let record = TabRecord(title: "One")
        let row = try #require(rowViews(in: listShowing([record], active: record.id)).first)
        let fill = try #require(row.subviews.first { $0 is ActiveFill })
        #expect((fill.layer?.cornerRadius ?? 0) >= 6)
    }

    /// With Smooth on the rows are moved, not reloaded, and a row that stays has to be told who's active now.
    @Test func smoothRowChangesLeaveTheRowsMatchingTheTabs() throws {
        let (one, two, three) = (TabRecord(title: "One"), TabRecord(title: "Two"), TabRecord(title: "Three"))
        let view = listShowing([one, two], active: one.id)
        try withMotion(.smooth) {
            view.update(records: [two, three], activeID: two.id)
            var rows = try rowViews(in: view)
            #expect(rows.map(title(of:)) == ["Two", "Three"])
            #expect(rows.map(hasFill) == [true, false])
            view.update(records: [three, two, one], activeID: one.id)
            rows = try rowViews(in: view)
            #expect(rows.map(title(of:)) == ["Three", "Two", "One"])
            #expect(rows.map(hasFill) == [false, false, true])
            view.update(records: [], activeID: nil)
            #expect(view.rowCount == 0)
        }
    }

    /// Every tab's every change arrives here, and a reload would take the hover off whatever the pointer is on.
    @Test func anUpdateWithNothingNewToShowLeavesTheRowsAlone() throws {
        var records = [TabRecord(url: URL(string: "https://one.example/a"), title: "One"), TabRecord(title: "Two")]
        let view = listShowing(records, active: records[0].id)
        closeButton(of: try #require(rowViews(in: view).first))?.alphaValue = 1 // the pointer is on it
        records[0].url = URL(string: "https://one.example/b")
        records[1].interactionState = Data([1])
        view.update(records: records, activeID: records[0].id)
        #expect(closeButton(of: try #require(rowViews(in: view).first))?.alphaValue == 1)
    }
    /// An unread count ticks in the title, and that may be the row the pointer is on.
    @Test func aTitleChangeUpdatesOnlyItsRowAndKeepsTheHover() throws {
        var records = [TabRecord(title: "One"), TabRecord(title: "Two")]
        let view = listShowing(records, active: records[0].id)
        let rows = try rowViews(in: view)
        closeButton(of: rows[1])?.alphaValue = 1
        records[1].title = "(1) Two"
        view.update(records: records, activeID: records[0].id)
        let after = try rowViews(in: view)
        try #require(after.count == 2)
        #expect(title(of: after[1]) == "(1) Two")
        #expect(after[0] === rows[0] && after[1] === rows[1])
        #expect(closeButton(of: after[1])?.alphaValue == 1)
    }
    /// A window that's never shown, because only a real pass over the table recycles rows. A row that leaves mid-hover never hears the pointer go.
    @Test func aRecycledRowDoesntKeepTheHover() throws {
        let records = (0..<40).map { TabRecord(title: "Tab \($0)") }
        let view = listShowing(records, active: records[0].id)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.displayIfNeeded()
        let table = try table(in: view)
        let hovered = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: false))
        hovered.mouseEntered(with: pointerEvent(.mouseEntered))
        closeButton(of: hovered)?.alphaValue = 1

        table.scrollRowToVisible(39)
        window.displayIfNeeded()
        let shown = table.rows(in: table.visibleRect)
        let rows = (shown.lowerBound..<shown.upperBound).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: false) }
        #expect(rows.contains { $0 === hovered })
        #expect(rows.allSatisfy { closeButton(of: $0)?.alphaValue == 0 })
        #expect(rows.allSatisfy { !hasFill($0) }) // the active tab is row 0, out of view
    }
    /// The rail is hidden most of the time, and whatever a tab did meanwhile has to be there when it opens.
    @Test func aTitleChangeWhileHiddenIsThereWhenTheListComesBack() throws {
        var records = [TabRecord(title: "One"), TabRecord(title: "Two")]
        let view = listShowing(records, active: records[0].id)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.displayIfNeeded()
        view.isHidden = true
        window.displayIfNeeded()

        records[1].title = "(1) Two"
        view.update(records: records, activeID: records[0].id)
        view.isHidden = false
        window.displayIfNeeded()
        #expect(title(of: try #require(table(in: view).view(atColumn: 0, row: 1, makeIfNecessary: false))) == "(1) Two")
    }
    @Test func aTitleChangeOutOfViewIsThereWhenTheRowScrollsIn() throws {
        var records = (0..<40).map { TabRecord(title: "Tab \($0)") }
        let view = listShowing(records, active: records[0].id)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.displayIfNeeded()
        let table = try table(in: view)
        #expect(table.view(atColumn: 0, row: 39, makeIfNecessary: false) == nil)

        records[39].title = "(1) Tab 39"
        view.update(records: records, activeID: records[0].id)
        table.scrollRowToVisible(39)
        window.displayIfNeeded()
        #expect(title(of: try #require(table.view(atColumn: 0, row: 39, makeIfNecessary: false))) == "(1) Tab 39")
    }
    @Test func theListScrollsOnlyWhenTheActiveTabChanges() throws {
        var records = (0..<40).map { TabRecord(title: "Tab \($0)") }
        let view = listShowing(records, active: records[0].id)
        let table = try table(in: view)
        table.scrollRowToVisible(39)
        let scrolled = table.visibleRect
        #expect(scrolled.minY > 0)

        records[39].title = "(1) Tab 39"
        view.update(records: records, activeID: records[0].id)
        #expect(table.visibleRect == scrolled)

        view.update(records: records, activeID: records[20].id)
        #expect(table.visibleRect.contains(table.rect(ofRow: 20)))
    }
    @Test func hoveringATabFillsItsRow() throws {
        let records = [TabRecord(title: "One"), TabRecord(title: "Two")]
        let view = listShowing(records, active: records[0].id)
        let rows = try rowViews(in: view)
        rows[1].mouseEntered(with: pointerEvent(.mouseEntered))
        #expect(rows.map(hasFill) == [true, true])
        rows[1].mouseExited(with: pointerEvent(.mouseExited))
        #expect(rows.map(hasFill) == [true, false])

        rows[0].mouseEntered(with: pointerEvent(.mouseEntered)) // the active row keeps its fill when the pointer goes
        rows[0].mouseExited(with: pointerEvent(.mouseExited))
        #expect(rows.map(hasFill) == [true, false])
    }
    /// An unread count ticks in the title of the row the pointer may be on.
    @Test func theHoverFillStaysThroughAnUpdate() throws {
        var records = [TabRecord(title: "One"), TabRecord(title: "Two")]
        let view = listShowing(records, active: records[0].id)
        try rowViews(in: view)[1].mouseEntered(with: pointerEvent(.mouseEntered))
        records[1].title = "(1) Two"
        view.update(records: records, activeID: records[0].id)
        #expect(try rowViews(in: view).map(hasFill) == [true, true])
    }
    @Test func aRowHiddenUnderThePointerComesBackWithoutTheHover() throws {
        let records = [TabRecord(title: "One"), TabRecord(title: "Two")]
        let view = listShowing(records, active: records[0].id)
        let rows = try rowViews(in: view)
        rows[1].mouseEntered(with: pointerEvent(.mouseEntered))
        view.isHidden = true
        view.isHidden = false
        #expect(rows.map(hasFill) == [true, false])
        #expect(closeButton(of: rows[1])?.alphaValue == 0)
    }
    @Test func switchingTabsMovesTheFill() throws {
        let records = [TabRecord(title: "One"), TabRecord(title: "Two")]
        let view = listShowing(records, active: records[0].id)
        view.update(records: records, activeID: records[1].id)
        #expect(try rowViews(in: view).map(hasFill) == [false, true])
    }
    @Test func aReorderRedrawsTheRows() throws {
        let records = [TabRecord(title: "One"), TabRecord(title: "Two")]
        let view = listShowing(records, active: records[0].id)
        view.update(records: records.reversed(), activeID: records[0].id)
        let rows = try rowViews(in: view)
        #expect(rows.map { title(of: $0) } == ["Two", "One"])

        var selected: UUID?
        view.onSelect = { selected = $0 }
        view.selectRow(0)
        #expect(selected == records[1].id)

        var closed: UUID? // each row holds its tab's close, so an update in place would close the wrong tab
        view.onClose = { closed = $0 }
        closeButton(of: rows[0])?.performClick(nil)
        #expect(closed == records[1].id)
    }
    @Test func eachRowIsNamedForItsTabAndTheActiveOneIsSelected() throws {
        var records = [TabRecord(title: "One"), TabRecord(url: URL(string: "https://two.example/"))]
        let view = listShowing(records, active: records[1].id)
        let table = try table(in: view)
        func spoken() -> [String] { accessibleRows(of: table).map { "\($0.label ?? "nil")\($0.isSelected ? " selected" : "")" } }
        #expect(spoken() == ["One", "two.example selected"])

        view.update(records: records, activeID: records[0].id)
        #expect(spoken() == ["One selected", "two.example"])

        records[0].title = "(1) One"
        view.update(records: records, activeID: records[0].id)
        #expect(spoken() == ["(1) One selected", "two.example"])
    }
    /// Reloading keeps the selected index, and the active tab may not be at that index any more.
    @Test func theActiveTabStaysSelectedThroughAReorderAndAClose() throws {
        let records = [TabRecord(title: "One"), TabRecord(title: "Two"), TabRecord(title: "Three")]
        let view = listShowing(records, active: records[0].id)
        let table = try table(in: view)

        view.update(records: records.reversed(), activeID: records[0].id)
        #expect(table.selectedRowIndexes == [2])

        view.update(records: Array(records.dropFirst()), activeID: records[1].id)
        #expect(table.selectedRowIndexes == [0])

        view.update(records: [], activeID: nil)
        #expect(table.selectedRowIndexes.isEmpty)
    }
    /// The title and address stay the same, so only the icon itself can say the row is out of date.
    @Test func aFaviconArrivingRefreshesItsRow() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let favicons = FaviconStore(directory: folder)
        let records = [TabRecord(url: URL(string: "https://one.example/"), title: "One")]
        let view = listShowing(records, active: records[0].id, favicons: favicons)
        let tile = icon(of: try #require(rowViews(in: view).first))

        try writeIcon(forHost: "one.example", in: folder)
        view.update(records: records, activeID: records[0].id)
        let shown = icon(of: try #require(rowViews(in: view).first))
        #expect(shown === favicons.image(forHost: "one.example"))
        #expect(shown !== tile)
    }
}

private final class FakeDrag: NSObject, NSDraggingInfo {
    let source: Any?
    init(source: Any?) { self.source = source }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { NSPasteboard(name: .drag) }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
