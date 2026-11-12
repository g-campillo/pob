import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct MotionTests {
    @Test func smoothIsOnUnlessMotionIsReduced() {
        withMotion(.smooth) { #expect(Motion.isOn) }
        withMotion(.smooth, reduced: true) { #expect(!Motion.isOn) }
        withMotion(.snappy) { #expect(!Motion.isOn) }
    }
    @Test func snappyAppliesAChangeAndFinishesAtOnce() {
        withMotion(.snappy) {
            let view = NSView()
            var finished = false
            Motion.animate { view.alphaValue = 0 } completion: { finished = true }
            #expect(view.alphaValue == 0)
            #expect(finished)
        }
    }
    @Test func snappyShowsAndHidesAtOnce() {
        withMotion(.snappy) {
            let view = NSView()
            view.setShown(false)
            #expect(view.isHidden)
            view.setShown(true)
            #expect(!view.isHidden && view.alphaValue == 1)
        }
    }
    /// The fade ends by hiding the view, so until then it's still there to be seen.
    @Test func smoothHidesAViewOnlyOnceItsFadeEnds() async {
        let view = NSView()
        withMotion(.smooth) {
            view.setShown(false)
            #expect(!view.isHidden)
        }
        #expect(await eventually { view.isHidden })
        #expect(view.alphaValue == 1) // ready for a plain show
    }
    /// The fade that was cut short still reports that it ended, and mustn't hide what has since come back.
    @Test func aViewShownAgainMidFadeStays() async throws {
        let view = NSView()
        withMotion(.smooth) {
            view.setShown(false)
            view.setShown(true)
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(!view.isHidden)
        #expect(view.alphaValue == 1)
    }
    /// A plain `isHidden = true` is a hide too, or the next show is taken for one already done and leaves the view hidden.
    @Test func aViewHiddenDirectlyComesBackWhenShown() async {
        let view = NSView()
        withMotion(.smooth) {
            view.setShown(true)
            view.isHidden = true
            view.setShown(true)
            #expect(!view.isHidden)
        }
        #expect(await eventually { view.alphaValue == 1 })
    }

    // MARK: The setting

    @Test func aSettingsFileFromBeforeTheSettingIsSmooth() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        try Data(#"{"transparency":0.3,"blur":10,"searchEngine":"bing"}"#.utf8).write(to: url)
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        #expect(model.motion == .smooth)
        #expect(model.searchEngine == .bing)
    }
    @Test func theStyleIsSavedAndASliderKeepsIt() {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        model.motion = .snappy
        let popover = AppearancePopover(model: model)
        popover.loadView()
        popover.transparencySlider.doubleValue = 40
        popover.slidersChanged()
        popover.slidersFinished()
        #expect(AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false).motion == .snappy)
    }
    @Test func settingsChangesTheAppearancesStyle() {
        let list = ProfileList(file: JSONFile(url: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")))
        let appearance = testAppearance()
        let model = SettingsModel(profiles: list, appearance: appearance)
        #expect(model.motion == .smooth)
        model.motion = .snappy
        #expect(appearance.motion == .snappy)
    }
}

@Suite struct HoverButtonTests {
    func borderless() -> HoverButton {
        let button = HoverButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        return button
    }

    @Test func hoveringPutsARoundedFillBehindAButton() {
        let button = borderless()
        #expect(button.layer?.backgroundColor == nil)
        button.mouseEntered(with: pointerEvent(.mouseEntered))
        #expect(button.layer?.backgroundColor != nil)
        #expect((button.layer?.cornerRadius ?? 0) > 0)
        button.mouseExited(with: pointerEvent(.mouseExited))
        #expect(button.layer?.backgroundColor == nil)
    }
    @Test func aButtonThatCantBeClickedShowsNoFill() {
        let button = borderless()
        button.isEnabled = false
        button.mouseEntered(with: pointerEvent(.mouseEntered))
        #expect(button.layer?.backgroundColor == nil)
    }
    @Test func aButtonWithItsOwnBorderKeepsItsOwnLook() {
        let button = HoverButton(title: "Settings…", target: nil, action: nil)
        button.mouseEntered(with: pointerEvent(.mouseEntered))
        #expect(button.layer?.backgroundColor == nil)
    }
    @Test func everyButtonInTheRailIsOne() {
        let rail = Rail(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        rail.bookmarks.update(folders: [], bookmarks: [Bookmark(id: UUID(), title: "One", url: URL(string: "https://one.example/")!, folder: nil)])
        rail.tabList.update(records: [TabRecord(title: "One")], activeID: nil)
        rail.layoutSubtreeIfNeeded()
        let buttons = rail.subviewsDeep.compactMap { $0 as? NSButton }
        #expect(buttons.count >= 11) // back, forward, reload, Bookmarks, New Folder, Add Bookmark, a tab's close, New Tab, profile, downloads, settings
        #expect(buttons.allSatisfy { $0 is HoverButton })
    }
    @Test func everyButtonInThePopoversIsOne() {
        let appearance = AppearancePopover(model: testAppearance(), site: "example.com")
        let signIn = SignInPopover(host: "example.com") { _, _ in }
        for popover in [appearance, signIn] as [NSViewController] {
            let buttons = popover.view.subviewsDeep.compactMap { $0 as? NSButton }
            #expect(!buttons.isEmpty && buttons.allSatisfy { $0 is HoverButton })
        }
    }
}
