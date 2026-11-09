import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct AppearancePopoverTests {
    @Test func slidersStartAtCurrentValuesAndHaveSpecRanges() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let popover = AppearancePopover(model: AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false))
        popover.loadView()
        #expect(popover.transparencySlider.doubleValue == 18)
        #expect(popover.transparencySlider.maxValue == 80)
        #expect(popover.blurSlider.doubleValue == 16)
        #expect(popover.blurSlider.maxValue == 40)
    }
    @Test func movingSlidersAppliesLiveAndFinishingSaves() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let store = SettingsStore(fileURL: url)
        let model = AppearanceModel(store: store, reduceTransparency: false)
        let popover = AppearancePopover(model: model)
        popover.loadView()
        popover.transparencySlider.doubleValue = 40
        popover.blurSlider.doubleValue = 30
        popover.slidersChanged()
        #expect(model.settings == AppearanceSettings(transparency: 0.4, blur: 30))
        #expect(store.load() == .standard)
        popover.slidersFinished()
        #expect(store.load() == AppearanceSettings(transparency: 0.4, blur: 30))
    }

    @Test func closingThePopoverSavesKeyboardChanges() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let store = SettingsStore(fileURL: url)
        let popover = AppearancePopover(model: AppearanceModel(store: store, reduceTransparency: false))
        popover.loadView()
        popover.blurSlider.doubleValue = 30
        popover.slidersChanged()
        popover.viewWillDisappear()
        #expect(store.load().blur == 30)
    }
    @Test func thePopoverShowsTheSiteSwitch() {
        var toggled = 0
        let popover = AppearancePopover(model: testAppearance(), site: "x.example", isBlocking: true, onToggleBlocking: { toggled += 1 })
        popover.loadView()
        #expect(popover.blockingCheckbox?.title == "Block ads on x.example")
        #expect(popover.blockingCheckbox?.state == .on)
        popover.blockingCheckbox?.performClick(nil)
        #expect(toggled == 1)
        #expect(popover.blockingCheckbox?.state == .off)
    }
    @Test func aPageWithNoHostHasNoSwitch() {
        let popover = AppearancePopover(model: testAppearance())
        popover.loadView()
        #expect(popover.blockingCheckbox == nil)
    }
}
