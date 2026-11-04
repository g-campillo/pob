import Foundation
import Testing
@testable import pob

@Suite struct FoundationTests {
    func tempFile() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json") }

    @Test func temporaryProfilesDontTouchRealData() {
        let profile = Profile.temporary()
        #expect(!profile.isPersistent)
        #expect(!profile.dataStore.isPersistent)
        #expect(profile.directory != Profile.initial.directory)
    }
    @Test func initialProfileKeepsItsStage1Identifier() {
        #expect(Profile.initial.id.uuidString == "6F0B5C2E-2F4B-4C6E-9B52-1F6B0A5D7C11")
        #expect(Profile.initial.directory.path().hasSuffix("pob/profiles/6F0B5C2E-2F4B-4C6E-9B52-1F6B0A5D7C11/"))
    }
    @Test func jsonFileRoundTripsAndCreatesFolders() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "a.json")
        let file = JSONFile<[String]>(url: url)
        #expect(file.load() == nil)
        try file.save(["x"])
        #expect(file.load() == ["x"])
    }
    @Test func jsonFileTreatsGarbageAsMissing() throws {
        let url = tempFile()
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(JSONFile<[String]>(url: url).load() == nil)
    }
    @Test func readingTellsAMissingFileFromAnUnreadableOne() throws {
        let url = tempFile()
        let file = JSONFile<[String]>(url: url)
        #expect(try file.read() == nil)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try file.read() }
        #expect(file.load() == nil)
    }
    @Test func siteSettingsPersistPerHost() {
        let file = JSONFile<[String: SiteSetting]>(url: tempFile())
        let settings = SiteSettings(file: file)
        settings["example.com"].zoom = 1.25
        #expect(SiteSettings(file: file)["example.com"].zoom == 1.25)
        #expect(SiteSettings(file: file)["other.com"] == SiteSetting())
    }
    @Test func everyObserverHearsAboutChanges() {
        let model = AppearanceModel(store: SettingsStore(fileURL: tempFile()), reduceTransparency: false)
        var calls = 0
        model.addObserver { calls += 1 }
        model.addObserver { calls += 1 }
        model.toggleSnap()
        #expect(calls == 2)
    }
}
