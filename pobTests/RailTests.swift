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
        let controller = WindowController(appearance: model, tab: Tab(profile: .initial))
        controller.perform(.toggleRail)
        #expect(controller.tab.webView.obscuredContentInsets.left == 256)
        #expect(controller.window?.standardWindowButton(.closeButton)?.isHidden == false)
        controller.perform(.toggleRail)
        #expect(controller.tab.webView.obscuredContentInsets.left == 0)
    }

    @Test func revealingImmediatelyPutsTheRailInPlaceForPopovers() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        let controller = WindowController(appearance: model, tab: Tab(profile: .initial))
        controller.revealRailImmediately()
        #expect(controller.rail.isHidden == false)
        #expect(controller.rail.frame.minX == Rail.inset)
    }
}

extension NSView {
    var subviewsDeep: [NSView] { subviews + subviews.flatMap(\.subviewsDeep) }
}
