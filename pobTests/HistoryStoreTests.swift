import Foundation
import Testing
@testable import pob

@Suite struct HistoryStoreTests {
    func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite")
    }
    func store() -> HistoryStore { HistoryStore(file: file()) }
    let deploy = URL(string: "https://ops.example.com/deploy")!

    @Test func findsPagesByTitlePrefix() async {
        let history = store()
        await history.record(url: deploy, title: "Deploy logs")
        #expect(await history.search("dep", limit: 5).map(\.url) == [deploy])
    }
    @Test func findsPagesByAddress() async {
        let history = store()
        await history.record(url: deploy, title: "Logs")
        #expect(await history.search("ops.exam", limit: 5).map(\.url) == [deploy])
    }
    @Test func repeatVisitsCountAndUpdateTheTitle() async {
        let history = store()
        await history.record(url: deploy, title: "Old")
        await history.record(url: deploy, title: "New")
        let entry = await history.search("new", limit: 5).first
        #expect(entry?.visitCount == 2)
        #expect(await history.search("old", limit: 5).isEmpty)
    }
    @Test func busierPagesRankFirst() async {
        let history = store()
        let quiet = URL(string: "https://example.com/deploy-quiet")!
        await history.record(url: quiet, title: "Deploy quiet")
        for _ in 0..<3 { await history.record(url: deploy, title: "Deploy busy") }
        #expect(await history.search("deploy", limit: 5).map(\.url) == [deploy, quiet])
    }
    @Test(arguments: [("c++", 1), ("\"quoted", 1), ("foo:bar", 1), ("-x", 1), ("a AND", 1), ("(", 0), ("*", 0), ("'", 0)])
    func symbolsInSearchesAreSafe(query: String, matches: Int) async {
        let history = store()
        await history.record(url: URL(string: "https://example.com/c++")!, title: "c++ \"quoted foo:bar -x a AND notes")
        #expect(await history.search(query, limit: 5).count == matches)
    }
    @Test func oldVisitsArePruned() async {
        let history = store()
        await history.record(url: deploy, title: "Deploy", at: .distantPast)
        await history.prune(before: Date().addingTimeInterval(-365 * 86_400))
        #expect(await history.search("deploy", limit: 5).isEmpty)
    }
    @Test func anUnopenableFileDoesntCrash() async {
        let history = HistoryStore(file: URL(fileURLWithPath: "/nonexistent/folder/h.sqlite"))
        await history.record(url: deploy, title: "x")
        #expect(await history.search("x", limit: 5).isEmpty)
    }
    @Test func aTitleArrivingAfterTheLoadUpdatesHistory() async {
        let history = store()
        await history.record(url: deploy, title: "")
        await history.updateTitle(url: deploy, title: "Deploy logs")
        let entry = await history.search("logs", limit: 5).first
        #expect(entry?.url == deploy)
        #expect(entry?.visitCount == 1)
    }
    @Test func aTitleForAnUnvisitedPageIsIgnored() async {
        let history = store()
        await history.updateTitle(url: deploy, title: "Deploy")
        #expect(await history.search("deploy", limit: 5).isEmpty)
    }
    @Test func aRepeatVisitWithoutATitleKeepsTheOldOne() async {
        let history = store()
        await history.record(url: deploy, title: "Deploy logs")
        await history.record(url: deploy, title: "")
        #expect(await history.search("logs", limit: 5).first?.visitCount == 2)
    }
    @Test func reopeningKeepsEntries() async {
        let path = file()
        await HistoryStore(file: path).record(url: deploy, title: "Deploy logs")
        #expect(await HistoryStore(file: path).search("logs", limit: 5).map(\.url) == [deploy])
    }
    @Test func finishedPagesLandInHistory() async {
        let profile = Profile.temporary()
        let tabs = TabManager(profile: profile, keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.webView.loadHTMLString("<title>Deploy</title>", baseURL: URL(string: "https://localhost/deploy")) }
        let found = await eventually { await profile.history.search("deploy", limit: 5).count == 1 }
        #expect(found)
    }
    @Test func aPageTitleReachesHistoryThroughTheTabManager() async {
        let profile = Profile.temporary()
        let tabs = TabManager(profile: profile, keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.webView.loadHTMLString("<title>Zebra</title>", baseURL: URL(string: "https://localhost/plain")) }
        let found = await eventually { await profile.history.search("zebra", limit: 5).first?.visitCount == 1 }
        #expect(found)
    }
}
