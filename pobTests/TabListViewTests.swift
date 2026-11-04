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
