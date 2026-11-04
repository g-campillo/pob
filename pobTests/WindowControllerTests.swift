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
}
