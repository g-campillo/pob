import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct WindowControllerTests {
    func make() -> (WindowController, AppearanceModel) {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        return (WindowController(appearance: model, tab: Tab(profile: .initial)), model)
    }

    @Test func windowIsClearAndChromeless() throws {
        let (controller, _) = make()
        let window = try #require(controller.window)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
    }
    @Test func windowButtonsStartHidden() throws {
        let (controller, _) = make()
        #expect(controller.window?.standardWindowButton(.closeButton)?.isHidden == true)
    }
    @Test func appearanceDrivesThePage() {
        let (controller, model) = make()
        #expect(abs(controller.tab.webView.alphaValue - 0.82) < 0.0001)
        model.toggleSnap()
        #expect(controller.tab.webView.alphaValue == 1)
    }
    @Test func privateBlurIsInUseOnThisMac() {
        #expect(!make().0.usesFallbackBlur)
    }
    @Test func snapCommandReachesTheModel() {
        let (controller, model) = make()
        controller.perform(.snapOpaque)
        #expect(model.isSnappedOpaque)
    }

    @Test func closingTargetsTheFrontWindow() {
        let (controller, _) = make()
        let popup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        #expect(controller.windowToClose(keyWindow: popup) === popup)
        #expect(controller.windowToClose(keyWindow: nil) === controller.window)
    }

    /// With nothing on screen and no page yet, a fully clear window can't be seen at all.
    @Test func blankWindowIsVisibleAndSnappingMakesItSolid() {
        let (controller, model) = make()
        #expect(controller.backdrop.alphaValue == 0.25)
        #expect(controller.backdrop.superview?.subviews.first === controller.backdrop)
        model.toggleSnap()
        #expect(controller.backdrop.alphaValue == 1)
    }
}
