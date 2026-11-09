import Foundation
import Testing
@testable import pob

@Suite struct ProfileListTests {
    func file() -> JSONFile<[ProfileInfo]> {
        JSONFile(url: FileManager.default.temporaryDirectory.appending(path: "pob-\(UUID().uuidString)/profiles.json"))
    }

    @Test func aMissingFileGivesTheStartingProfile() {
        #expect(ProfileList(file: file()).all == [ProfileInfo(id: Profile.initialID, name: "Main")])
    }
    @Test func changesSurviveARelaunch() {
        let file = file()
        let list = ProfileList(file: file)
        let work = list.add(name: "Work")
        list.rename(Profile.initialID, to: "Home")
        #expect(ProfileList(file: file).all == [ProfileInfo(id: Profile.initialID, name: "Home"), work])
        list.remove(Profile.initialID)
        #expect(ProfileList(file: file).all == [work])
    }
    @Test func theLastProfileStays() {
        let list = ProfileList(file: file())
        list.remove(Profile.initialID)
        #expect(list.all.count == 1)
    }
    @Test func blankNamesAreIgnoredAndLongOnesCut() {
        let list = ProfileList(file: file())
        list.rename(Profile.initialID, to: "   ")
        #expect(list.name(of: Profile.initialID) == "Main")
        list.rename(Profile.initialID, to: String(repeating: "x", count: 60))
        #expect(list.name(of: Profile.initialID)?.count == 40)
        #expect(list.add(name: " ").name == "Profile 2") // a blank new name gets a numbered one
    }
    @Test func anUnreadableFileFallsBackAndIsKept() throws {
        let file = file()
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        #expect(ProfileList(file: file).all.map(\.id) == [Profile.initialID])
        #expect(FileManager.default.fileExists(atPath: file.url.appendingPathExtension("unreadable").path()))
    }
    @Test func observersHearEveryChange() {
        let list = ProfileList(file: file())
        var heard = 0
        list.addObserver { heard += 1 }
        let work = list.add(name: "Work")
        list.rename(work.id, to: "Job")
        list.remove(work.id)
        #expect(heard == 3)
    }
}
