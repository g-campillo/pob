import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct RailTests {
    @Test func edgeOpensAndLeavingCloses() {
        var state = RailState()
        state.pointerDwelledAtEdge()
        #expect(state.visibility == .hover)
        state.pointerLeftRail()
        #expect(state.visibility == .hidden)
    }
    @Test func shortcutPinsAndHides() {
        var state = RailState()
        state.toggleShortcut()
        #expect(state.visibility == .pinned)
        state.pointerLeftRail()
        #expect(state.visibility == .pinned)
        state.toggleShortcut()
        #expect(state.visibility == .hidden)
    }
    @Test func shortcutPinsARailOpenOnHover() {
        var state = RailState()
        state.pointerDwelledAtEdge()
        state.toggleShortcut()
        #expect(state.visibility == .pinned)
    }
    @Test func typingKeepsTheRailOpen() {
        var state = RailState()
        state.beginEditingAddress()
        #expect(state.visibility == .hover)
        state.pointerLeftRail()
        #expect(state.visibility == .hover)
        state.endEditingAddress(pointerInsideRail: false)
        #expect(state.visibility == .hidden)
    }
    @Test func finishingWithThePointerInsideKeepsItOpen() {
        var state = RailState()
        state.beginEditingAddress()
        state.endEditingAddress(pointerInsideRail: true)
        #expect(state.visibility == .hover)
    }
    @Test func edgeStripNeverTakesClicks() {
        let strip = EdgeStrip(frame: NSRect(x: 0, y: 0, width: 8, height: 400))
        #expect(strip.hitTest(NSPoint(x: 4, y: 200)) == nil)
    }
    @Test func railIsRegularGlass() throws {
        let glass = try #require(Rail(frame: .zero).subviewsDeep.compactMap { $0 as? NSGlassEffectView }.first)
        #expect(glass.style == .regular)
    }
    @Test func pinningMovesThePageOverAndHoverDoesNot() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = WindowController(appearance: model, tabs: tabs)
        controller.perform(.toggleRail)
        #expect(controller.tab?.webView.obscuredContentInsets.left == 256)
        #expect(controller.window?.standardWindowButton(.closeButton)?.isHidden == false)
        controller.perform(.toggleRail)
        #expect(controller.tab?.webView.obscuredContentInsets.left == 0)
    }

    @Test func revealingImmediatelyPutsTheRailInPlaceForPopovers() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        let controller = WindowController(appearance: model, tabs: TabManager(profile: .temporary(), keepsSpare: false))
        controller.revealRailImmediately()
        #expect(controller.rail.isHidden == false)
        #expect(controller.rail.frame.minX == Rail.inset)
    }
}

@Suite struct PinnedBookmarksTests {
    let bookmark = Bookmark(id: UUID(), title: "One", url: URL(string: "https://one.example/")!, folder: nil, isPinned: true)

    func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A click is a press and a release, and a button rebuilt between the two never fires.
    @Test func anUpdateWithNothingNewKeepsTheButtons() throws {
        let favicons = FaviconStore(directory: try folder())
        let view = PinnedBookmarksView()
        view.update(bookmarks: [bookmark], favicons: favicons)
        let button = try #require(view.subviews.first)
        view.update(bookmarks: [bookmark], favicons: favicons)
        #expect(view.subviews.count == 1)
        #expect(view.subviews.first === button)
    }
    @Test func aRenamedBookmarkShowsItsNewTitle() {
        let favicons = FaviconStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let view = PinnedBookmarksView()
        view.update(bookmarks: [bookmark], favicons: favicons)
        var renamed = bookmark
        renamed.title = "Two"
        view.update(bookmarks: [renamed], favicons: favicons)
        #expect(view.subviews.map(\.toolTip) == ["Two"])
    }
    @Test func aRemovedBookmarkGoes() {
        let favicons = FaviconStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let view = PinnedBookmarksView()
        view.update(bookmarks: [bookmark], favicons: favicons)
        view.update(bookmarks: [], favicons: favicons)
        #expect(view.subviews.isEmpty)
    }
    /// The bookmark stays the same, so only the icon itself can say the button is out of date.
    @Test func aFaviconArrivingRefreshesTheButton() throws {
        let folder = try folder()
        let favicons = FaviconStore(directory: folder)
        let view = PinnedBookmarksView()
        view.update(bookmarks: [bookmark], favicons: favicons)
        let tile = (view.subviews.first as? NSButton)?.image

        try writeIcon(forHost: "one.example", in: folder)
        view.update(bookmarks: [bookmark], favicons: favicons)
        let shown = (view.subviews.first as? NSButton)?.image
        #expect(shown === favicons.image(forHost: "one.example"))
        #expect(shown !== tile)
    }
}

extension NSView {
    var subviewsDeep: [NSView] { subviews + subviews.flatMap(\.subviewsDeep) }
}
