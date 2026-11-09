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
    /// Only a web view needs the store, and building it for the real identifier makes folders in the user's own store.
    /// Reflection reads the storage without building it, and a renamed property fails here rather than passing.
    @Test func readingTheInitialProfileBuildsNoDataStore() throws {
        let store = try #require(Mirror(reflecting: Profile.initial).children.first { $0.label?.contains("dataStore") == true })
        #expect("\(store.value)" == "nil")
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
    /// The next save replaces the file, so what it holds would otherwise be gone.
    @Test func anUnreadableFileIsCopiedOverAnyEarlierCopyAndLeftInPlace() throws {
        let url = tempFile()
        let copy = url.appendingPathExtension("unreadable")
        try "earlier".write(to: copy, atomically: true, encoding: .utf8)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(JSONFile<[String]>(url: url).load() == nil)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "not json")
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }
    @Test func aMissingOrReadableFileLeavesNoCopy() throws {
        let url = tempFile()
        let file = JSONFile<[String]>(url: url)
        #expect(file.load() == nil)
        try file.save(["x"])
        #expect(file.load() == ["x"])
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path()))
    }
    @Test func aFailedCopyIsReportedSoTheFileCanBeKept() throws {
        let url = tempFile()
        let file = JSONFile<[String]>(url: url)
        #expect(file.loadChecked().isReplaceable)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: url.appendingPathExtension("unreadable").appending(path: "in the way"), withIntermediateDirectories: true)

        let loaded = file.loadChecked()
        #expect(loaded.value == nil)
        #expect(!loaded.isReplaceable)
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
    // Only paths and identity: no store of a persistent profile is touched.
    @Test func persistentGivesOneProfilePerID() {
        let id = UUID()
        defer { Profile.forget(id: id) }
        #expect(Profile.persistent(id: id) === Profile.persistent(id: id))
        #expect(Profile.persistent(id: Profile.initialID) === Profile.initial)
        #expect(Profile.persistent(id: id).directory.path().hasSuffix("pob/profiles/\(id.uuidString)/"))
        #expect(Profile.persistent(id: id).usesSharedRules)
        #expect(!Profile.temporary().usesSharedRules) // tests keep their rules in their own folder
    }
    @Test func forgettingAProfileGivesAFreshOneNextTime() {
        let id = UUID()
        let first = Profile.persistent(id: id)
        Profile.forget(id: id)
        #expect(Profile.persistent(id: id) !== first)
        Profile.forget(id: id)
    }
}
