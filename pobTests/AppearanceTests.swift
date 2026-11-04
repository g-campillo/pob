import Foundation
import Testing
@testable import pob

@Suite struct AppearanceTests {
    func tempFile() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json") }

    @Test func defaultsMatchSpec() {
        #expect(AppearanceSettings.standard == AppearanceSettings(transparency: 0.18, blur: 16))
    }
    @Test func clampsToRange() {
        #expect(AppearanceSettings(transparency: 2, blur: 99).clamped == AppearanceSettings(transparency: 0.8, blur: 40))
        #expect(AppearanceSettings(transparency: -1, blur: -5).clamped == AppearanceSettings(transparency: 0, blur: 0))
    }
    @Test func missingFileGivesDefaults() {
        #expect(SettingsStore(fileURL: tempFile()).load() == .standard)
    }
    @Test(arguments: ["not json", "{}", "{\"transparency\":\"high\",\"blur\":16}", ""])
    func corruptFileGivesDefaults(contents: String) throws {
        let url = tempFile()
        try contents.write(to: url, atomically: true, encoding: .utf8)
        #expect(SettingsStore(fileURL: url).load() == .standard)
    }
    @Test func outOfRangeFileIsClamped() throws {
        let url = tempFile()
        try "{\"transparency\":5,\"blur\":500}".write(to: url, atomically: true, encoding: .utf8)
        #expect(SettingsStore(fileURL: url).load() == AppearanceSettings(transparency: 0.8, blur: 40))
    }
    @Test func saveCreatesFoldersAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "settings.json")
        let store = SettingsStore(fileURL: url)
        try store.save(AppearanceSettings(transparency: 0.4, blur: 20))
        #expect(store.load() == AppearanceSettings(transparency: 0.4, blur: 20))
    }
    @Test func effectiveUsesSettings() {
        let model = AppearanceModel(store: SettingsStore(fileURL: tempFile()), reduceTransparency: false)
        #expect(abs(model.effective.pageAlpha - 0.82) < 0.0001)
        #expect(model.effective.blurRadius == 16)
    }
    @Test func snapGoesOpaqueAndRestores() {
        let model = AppearanceModel(store: SettingsStore(fileURL: tempFile()), reduceTransparency: false)
        model.toggleSnap()
        #expect(model.effective == EffectiveAppearance(pageAlpha: 1, blurRadius: 0))
        model.toggleSnap()
        #expect(model.effective.blurRadius == 16)
    }
    @Test func reduceTransparencyForcesOpaqueWhileRunning() {
        let model = AppearanceModel(store: SettingsStore(fileURL: tempFile()), reduceTransparency: false)
        var changes = 0
        model.onChange = { changes += 1 }
        model.reduceTransparency = true
        #expect(model.effective == EffectiveAppearance(pageAlpha: 1, blurRadius: 0))
        model.reduceTransparency = false
        #expect(model.effective.blurRadius == 16)
        #expect(changes == 2)
    }
}
