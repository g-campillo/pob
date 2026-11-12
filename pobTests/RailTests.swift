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
    /// The lists above it come and go, and the bottom row mustn't ride up when neither is showing.
    @Test func theBottomRowStaysAtTheBottomWhateverTheListsShow() {
        let rail = Rail(frame: NSRect(x: 0, y: 0, width: Rail.width, height: 600))
        func frame(of view: NSView) -> NSRect {
            rail.layoutSubtreeIfNeeded()
            return rail.convert(view.bounds, from: view)
        }
        let settings = frame(of: rail.settingsButton)
        #expect(settings.minY < 20) // the stack's 10 pt margin, not somewhere up the rail
        #expect(frame(of: rail.tabList).minY - settings.maxY <= 12) // the tab list still fills the space down to it

        rail.showSuggestions([SwitcherRow(target: .command(.reload), title: "Reload", subtitle: "", section: "")])
        #expect(frame(of: rail.settingsButton) == settings) // one short row of suggestions

        rail.showSuggestions([])
        rail.tabList.isHidden = true
        #expect(frame(of: rail.settingsButton) == settings) // neither list
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

    // MARK: Smooth animations, where the rail is still on screen while it slides out

    private func pinned() -> WindowController {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = WindowController(appearance: testAppearance(), tabs: tabs)
        controller.perform(.toggleRail)
        return controller
    }
    @Test func theRailStaysUpWhileItSlidesOutAndThenHides() async {
        let controller = pinned()
        withMotion(.smooth) {
            controller.perform(.toggleRail)
            #expect(!controller.rail.isHidden)
            controller.applyRailState() // nothing changed, and the slide mustn't be cut short
            #expect(!controller.rail.isHidden)
        }
        #expect(await eventually { controller.rail.isHidden })
        #expect(controller.rail.frame.minX == -(Rail.width + Rail.inset))
    }
    @Test func showingTheRailAgainMidSlideKeepsIt() async throws {
        let controller = pinned()
        withMotion(.smooth) {
            controller.perform(.toggleRail)
            controller.perform(.toggleRail)
        }
        try await Task.sleep(for: .milliseconds(700)) // both slides have ended by now
        #expect(!controller.rail.isHidden)
        #expect(controller.rail.frame.minX == Rail.inset)
        #expect(controller.window?.standardWindowButton(.closeButton)?.alphaValue == 1)
    }
    @Test func hidingTheRailMidSlideInStillHidesIt() async {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = WindowController(appearance: testAppearance(), tabs: tabs)
        withMotion(.smooth) {
            controller.perform(.toggleRail)
            #expect(!controller.rail.isHidden)
            controller.perform(.toggleRail)
            #expect(!controller.rail.isHidden)
        }
        #expect(await eventually { controller.rail.isHidden })
        #expect(controller.rail.frame.minX == -(Rail.width + Rail.inset)) // it slid back out before it went
    }
    /// A popover anchors to the rail, so this can't wait for a slide.
    @Test func revealingImmediatelyStopsASlideOut() async throws {
        let controller = pinned()
        withMotion(.smooth) {
            controller.perform(.toggleRail)
            controller.revealRailImmediately()
            #expect(controller.rail.frame.minX == Rail.inset)
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!controller.rail.isHidden)
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

    /// Sites' icons are square, and nothing else pob draws is.
    @Test func aStoredIconComesBackWithRoundedCorners() throws {
        let folder = try folder()
        let square = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let png = try #require(square.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
        try png.write(to: folder.appending(path: FaviconStore.fileName(forHost: "square.example")))

        let icon = try #require(FaviconStore(directory: folder).image(forHost: "square.example"))
        let pixels = try #require(icon.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        #expect(pixels.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        #expect(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)?.alphaComponent == 1)
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
