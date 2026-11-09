import AppKit
import Foundation
import Testing
import WebKit
@testable import pob

final class CountingScheme: NSObject, WKURLSchemeHandler {
    /// What the site's root answers with, so a restored tab has a real page to come back to.
    var page: String?
    private(set) var requested: [String] = []
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        requested.append(task.request.url?.lastPathComponent ?? "")
        if let page, let url = task.request.url, url.path().isEmpty || url.path() == "/" {
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: page.utf8.count, textEncodingName: "utf-8"))
            task.didReceive(Data(page.utf8))
            task.didFinish()
        } else {
            task.didFailWithError(URLError(.cancelled))
        }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

private final class CountingController: WKUserContentController {
    private(set) var added = 0
    override func add(_ contentRuleList: WKContentRuleList) {
        added += 1
        super.add(contentRuleList)
    }
}

/// Kept for the same reason as `FakeNavigationAction`.
private final class FakeAttachment: WKNavigationResponse {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init()
        _ = Unmanaged.passRetained(self)
    }

    override var isForMainFrame: Bool { true }
    override var canShowMIMEType: Bool { true }
    override var response: URLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Disposition": "attachment"])!
    }
}

/// The longest the main actor went without getting to run.
private final class Heartbeat {
    private var last = ContinuousClock.now
    private(set) var longestStall = Duration.zero

    func beat() {
        longestStall = max(longestStall, .now - last)
        last = .now
    }
}

/// Answers `download` with no network: the path picks the answer.
private nonisolated final class StubServer: URLProtocol {
    static let good = "[Adblock Plus 2.0]\n||ads.example^\n"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let client, let url = request.url else { return }
        let status = url.lastPathComponent == "missing" ? 404 : 200
        let body = url.lastPathComponent == "binary" ? Data([0xFF, 0xFE, 0x00, 0xC0]) : Data(Self.good.utf8)
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }
}

/// A class, because compiled rules run to tens of megabytes and each test has to clean up after itself.
@Suite(.timeLimit(.minutes(1))) final class ContentBlockerTests {
    private let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let later = Date.now.addingTimeInterval(8 * 86_400)
    let header = "[Adblock Plus 2.0]\n! Title: EasyList\n"
    let blockedAndAllowed = "<img src='pobtest://x/blocked.png'><img src='pobtest://x/allowed.png'>"
    let bothImages = "new Image().src = 'pobtest://x/blocked.png'; new Image().src = 'pobtest://x/allowed.png'; true"

    deinit { try? FileManager.default.removeItem(at: scratch) }

    func folder() throws -> URL {
        let url = scratch.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func blocker(
        bundled: URL? = nil,
        fetch: @escaping (URL) async throws -> String = { _ in throw URLError(.notConnectedToInternet) }
    ) throws -> ContentBlocker {
        let resources = try bundled ?? #require(Bundle(for: Tab.self).resourceURL)
        return ContentBlocker(cacheDirectory: try folder(), bundledDirectory: resources, fetch: fetch)
    }
    func listFolder(_ rule: String) throws -> URL {
        let bundled = try folder()
        try rule.write(to: bundled.appending(path: "easylist.txt"), atomically: true, encoding: .utf8)
        return bundled
    }
    /// Both lists on disk, so neither counts as never having been fetched.
    func bothLists(_ easylist: String = "/blocked.png", easyprivacy: String = "/tracker.png") throws -> URL {
        let bundled = try listFolder(easylist)
        try easyprivacy.write(to: bundled.appending(path: "easyprivacy.txt"), atomically: true, encoding: .utf8)
        return bundled
    }
    func manyRules(_ count: Int) -> String {
        header + (0..<count).map { "||ads\($0).example^" }.joined(separator: "\n")
    }
    /// A tab whose `pobtest:` requests are counted.
    func countedTab(_ profile: Profile, page: String? = nil) -> (Tab, CountingScheme) {
        let scheme = CountingScheme()
        scheme.page = page
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "pobtest")
        return (Tab(profile: profile, configuration: configuration), scheme)
    }
    func profile(blockingWith blocker: ContentBlocker) -> Profile {
        let profile = Profile.temporary()
        profile.contentBlocker = blocker
        return profile
    }
    func load(_ html: String, in tab: Tab, at address: String = "pobtest://x/") async {
        await finishLoading(tab) { tab.webView.loadHTMLString(html, baseURL: URL(string: address)) }
    }
    /// A page from the scheme, because a reload asks for the address again and an HTML string has none.
    func open(_ tab: Tab) async {
        await finishLoading(tab) { tab.webView.load(URLRequest(url: URL(string: "pobtest://x/")!)) }
    }
    func rules(of blocker: ContentBlocker, _ name: String = "easylist") -> WKContentRuleList? {
        blocker.ruleLists.first { $0.identifier == name }
    }
    /// The page asks after it's loaded, so nothing but the rules in force right now decides. `allowed.png` shows the question reached WebKit.
    func askForBoth(in tab: Tab, _ scheme: CountingScheme) async throws -> Bool {
        let earlier = scheme.requested.count
        _ = try await tab.webView.evaluateJavaScript(bothImages)
        #expect(await eventually { scheme.requested.dropFirst(earlier).contains("allowed.png") })
        return scheme.requested.dropFirst(earlier).contains("blocked.png")
    }

    // MARK: Converting and compiling

    @Test func convertsANetworkRule() {
        #expect(ContentBlocker.convert("||ads.example^").contains("ads"))
    }
    @Test func bundledListsCompile() async throws {
        let blocker = try blocker()
        await blocker.prepare()
        #expect(blocker.ruleLists.count == 2)
    }
    /// The whole way through: the profile's own blocker on the app's own resources, one real rule from each list and real WebKit.
    @Test func aRealRuleFromEachListStopsARealRequestAndNothingElse() async throws {
        let resources = try #require(Bundle.main.resourceURL)
        #expect(try String(contentsOf: resources.appending(path: "easylist.txt"), encoding: .utf8).contains("\n.aspx?adid=\n"))
        #expect(try String(contentsOf: resources.appending(path: "easyprivacy.txt"), encoding: .utf8).contains("\n||googletagmanager.com^\n"))

        let profile = Profile.temporary()
        defer { try? FileManager.default.removeItem(at: profile.directory) }
        await profile.contentBlocker.prepare()
        #expect(profile.contentBlocker.ruleLists.count == 2)
        let page = """
            <img src='pobtest://example.org/banner.aspx?adid=1'>
            <img src='pobtest://googletagmanager.com/pixel.png'>
            <img src='pobtest://example.org/logo.png'>
            """
        let (tab, scheme) = countedTab(profile)
        await load(page, in: tab, at: "pobtest://example.org/")
        #expect(scheme.requested == ["logo.png"])

        profile.siteSettings["example.org"].adBlockerOff = true
        let (next, unblocked) = countedTab(profile)
        await load(page, in: next, at: "pobtest://example.org/")
        #expect(Set(unblocked.requested) == ["banner.aspx", "pixel.png", "logo.png"])
    }
    @Test func theListsShipInTheAppsOwnResources() throws {
        let resources = try #require(Bundle.main.resourceURL)
        for list in ContentBlocker.lists {
            #expect(FileManager.default.fileExists(atPath: resources.appending(path: "\(list.name).txt").path()), "\(list.name)")
        }
    }
    @Test func theListNamesAreFixed() {
        #expect(ContentBlocker.lists.map(\.name) == ["easylist", "easyprivacy"])
        #expect(ContentBlocker.lists.map(\.remote.absoluteString) == ["https://easylist.to/easylist/easylist.txt", "https://easylist.to/easylist/easyprivacy.txt"])
    }
    @Test func aListThatFailsIsSkipped() async throws {
        let blocker = try blocker(bundled: listFolder("||ads.example^"))   // no easyprivacy.txt
        await blocker.prepare()
        #expect(blocker.ruleLists.count == 1)
    }
    /// Scripts and anything else that would run as code stay out, because the lists come from outside.
    @Test func nothingFromAListRunsAsCode() {
        let json = ContentBlocker.convert("""
            example.com#%#window.hacked = 1
            example.com#%#//scriptlet('abort-on-property-read', 'x')
            example.com#$#body { background: red }
            ||ads.example^
            """)
        #expect(json.contains("ads"))
        #expect(!json.contains("hacked"))
        #expect(!json.contains("scriptlet"))
        #expect(!json.contains("background"))
    }
    @Test func compiledRulesAreUsedWithoutTheBundledText() async throws {
        let cache = try folder()
        let first = ContentBlocker(cacheDirectory: cache, bundledDirectory: try bothLists(), fetch: { _ in "" })
        await first.prepare()

        let second = ContentBlocker(cacheDirectory: cache, bundledDirectory: try folder(), fetch: { _ in "" })
        await second.prepare()
        #expect(second.ruleLists.count == 2)
    }
    @Test func aTemporaryProfileKeepsItsRulesInItsOwnFolder() {
        let profile = Profile.temporary()
        _ = profile.contentBlocker
        #expect(FileManager.default.fileExists(atPath: profile.directory.appending(path: "rules").path()))
    }
    /// Reflection reads the storage without building it, and a renamed property fails here rather than passing.
    @Test func hostedTestsNeverBuildTheRealProfilesBlocker() throws {
        let blocker = try #require(Mirror(reflecting: Profile.initial).children.first { $0.label?.contains("contentBlocker") == true })
        #expect("\(blocker.value)" == "nil")
    }

    // MARK: Refreshing

    @Test func aFailedRefreshKeepsTheLastGoodRules() async throws {
        let blocker = try blocker(bundled: bothLists())
        await blocker.prepare()
        let before = blocker.ruleLists
        await blocker.refreshIfStale(now: .now.addingTimeInterval(8 * 86_400))
        #expect(blocker.ruleLists.count == 2)
        #expect(zip(before, blocker.ruleLists).allSatisfy { $0 === $1 })
    }
    @Test func aFreshCacheSkipsTheNetwork() async throws {
        var fetched = 0
        let blocker = try blocker(bundled: bothLists(), fetch: { _ in fetched += 1; return "||ads.example^" })
        await blocker.prepare()
        await blocker.refreshIfStale(now: .now)
        #expect(fetched == 0)
    }
    @Test func theWeeklyClockStartsWhenTheBundledTextCompiles() async throws {
        var fetched = 0
        let blocker = try blocker(bundled: bothLists(), fetch: { [header] _ in fetched += 1; return header + "/new.png" })
        let start = Date.now
        await blocker.prepare()
        await blocker.refreshIfStale(now: start.addingTimeInterval(7 * 86_400 - 60))
        #expect(fetched == 0)
        await blocker.refreshIfStale(now: Date.now.addingTimeInterval(7 * 86_400 + 60))
        #expect(fetched == 2)
    }
    @Test func theWeeklyClockRestartsAfterARefreshAndSurvivesARelaunch() async throws {
        var fetched = 0
        let cache = try folder()
        let fetch: (URL) async throws -> String = { [header] _ in fetched += 1; return header + "/new.png" }
        let first = ContentBlocker(cacheDirectory: cache, bundledDirectory: try bothLists(), fetch: fetch)
        await first.prepare()
        await first.refreshIfStale(now: later)
        #expect(fetched == 2)

        let second = ContentBlocker(cacheDirectory: cache, bundledDirectory: try folder(), fetch: fetch)
        await second.prepare()
        await second.refreshIfStale(now: later.addingTimeInterval(86_400))
        #expect(fetched == 2)
        await second.refreshIfStale(now: later.addingTimeInterval(8 * 86_400))
        #expect(fetched == 4)
    }
    @Test func nothingIsFetchedUntilTheRulesArePrepared() async throws {
        var fetched = 0
        let blocker = try blocker(bundled: bothLists(), fetch: { _ in fetched += 1; return "" })
        await blocker.refreshIfStale(now: later)
        #expect(fetched == 0)
    }
    @Test func onlyOneRefreshRunsAtATime() async throws {
        var fetched = 0
        let gate = AsyncStream<Void>.makeStream()
        let blocker = try blocker(bundled: bothLists(), fetch: { [header] _ in
            fetched += 1
            for await _ in gate.stream {}
            return header + "/new.png"
        })
        await blocker.prepare()
        let first = Task { await blocker.refreshIfStale(now: later) }
        #expect(await eventually { fetched == 1 })
        await blocker.refreshIfStale(now: later)
        #expect(fetched == 1)
        gate.continuation.finish()
        await first.value
        #expect(fetched == 2) // one call per list, so the first refresh went on to the second list
    }
    /// The timer ticks every minute, so without a pause a dead network would be asked about both lists all day.
    @Test func aFailedRefreshWaitsAnHourToTryAgain() async throws {
        var fetched = 0
        let blocker = try blocker(bundled: bothLists(), fetch: { _ in fetched += 1; throw URLError(.timedOut) })
        await blocker.prepare()
        await blocker.refreshIfStale(now: later)
        #expect(fetched == 2)
        await blocker.refreshIfStale(now: later.addingTimeInterval(60))
        #expect(fetched == 2)
        await blocker.refreshIfStale(now: later.addingTimeInterval(3_600))
        #expect(fetched == 4)
    }
    @Test func aRetryAsksOnlyForTheListThatFailed() async throws {
        var asked: [String] = []
        var failing = true
        let blocker = try blocker(bundled: bothLists(), fetch: { [header] url in
            asked.append(url.lastPathComponent)
            if failing, url.lastPathComponent == "easyprivacy.txt" { throw URLError(.timedOut) }
            return header + "/new.png"
        })
        await blocker.prepare()
        await blocker.refreshIfStale(now: later)
        failing = false
        await blocker.refreshIfStale(now: later.addingTimeInterval(3_600))
        #expect(asked == ["easylist.txt", "easyprivacy.txt", "easyprivacy.txt"])
    }
    /// A captive portal or an error page answers 200 too.
    @Test(arguments: [
        "<!DOCTYPE html><html><body>Sign in to the Wi-Fi</body></html>",
        "{\"error\":\"not found\"}",
        "Service Unavailable",
        "||ads.example^",
        "",
    ])
    func textThatIsntAFilterListIsRefused(text: String) async throws {
        let blocker = try blocker(bundled: bothLists(), fetch: { _ in text })
        await blocker.prepare()
        let before = blocker.ruleLists
        await blocker.refreshIfStale(now: later)
        #expect(blocker.ruleLists.count == 2)
        #expect(zip(before, blocker.ruleLists).allSatisfy { $0 === $1 })
    }
    @Test func aListWithFarFewerRulesIsRefused() async throws {
        let few = manyRules(40)
        let blocker = try blocker(bundled: bothLists(manyRules(100)), fetch: { _ in few })
        await blocker.prepare()
        let before = rules(of: blocker)
        await blocker.refreshIfStale(now: later)
        #expect(rules(of: blocker) === before)
    }
    @Test func aHeaderWithNoRulesIsRefused() async throws {
        let blocker = try blocker(bundled: bothLists(manyRules(10), easyprivacy: manyRules(10)), fetch: { [header] _ in header })
        await blocker.prepare()
        let before = blocker.ruleLists
        await blocker.refreshIfStale(now: later)
        #expect(zip(before, blocker.ruleLists).allSatisfy { $0 === $1 })
    }
    /// Past WebKit's limit the converter cuts from the end, which is where the exceptions are, so a page would break.
    /// Refused after converting and before compiling, so nothing but the conversion can hold the main actor up here,
    /// and a conversion that ran on it would stall it for nearly all of the time this takes.
    @Test func aListPastWebKitsLimitIsRefusedAndConvertingItLeavesTheMainActorFree() async throws {
        let tooMany = manyRules(150_001)
        let blocker = try blocker(bundled: bothLists(), fetch: { url in
            guard url.lastPathComponent == "easylist.txt" else { throw URLError(.timedOut) }
            return tooMany
        })
        await blocker.prepare()
        let before = blocker.ruleLists

        let heartbeat = Heartbeat()
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in MainActor.assumeIsolated { heartbeat.beat() } }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let elapsed = await ContinuousClock().measure { await blocker.refreshIfStale(now: later) }
        heartbeat.beat() // a stall that lasted to the end has had no beat to end it

        #expect(zip(before, blocker.ruleLists).allSatisfy { $0 === $1 })
        #expect(heartbeat.longestStall < elapsed / 2)
    }
    /// Lists lose rules from week to week, and the comparison has to survive a relaunch to catch a bad one after it.
    @Test func anOrdinaryUpdateIsAcceptedAndTheCountSurvivesARelaunch() async throws {
        let cache = try folder()
        var answer = manyRules(70)
        let fetch: (URL) async throws -> String = { _ in answer }
        let first = ContentBlocker(cacheDirectory: cache, bundledDirectory: try bothLists(manyRules(100), easyprivacy: manyRules(100)), fetch: fetch)
        await first.prepare()
        let before = rules(of: first)
        await first.refreshIfStale(now: later)
        #expect(rules(of: first) !== before)

        answer = manyRules(30)
        let second = ContentBlocker(cacheDirectory: cache, bundledDirectory: try folder(), fetch: fetch)
        await second.prepare()
        let kept = rules(of: second)
        await second.refreshIfStale(now: later.addingTimeInterval(8 * 86_400))
        #expect(rules(of: second) === kept)
    }
    /// A list that's refused has to leave nothing behind, or the next launch would load it.
    @Test func aRefusedListNeverReachesTheCompiledRules() async throws {
        let cache = try folder()
        let first = ContentBlocker(cacheDirectory: cache, bundledDirectory: try bothLists(), fetch: { _ in "<html>portal</html>" })
        await first.prepare()
        await first.refreshIfStale(now: later)

        let second = ContentBlocker(cacheDirectory: cache, bundledDirectory: try folder(), fetch: { _ in "" })
        await second.prepare()
        let (tab, scheme) = countedTab(profile(blockingWith: second))
        await load(blockedAndAllowed, in: tab)
        #expect(scheme.requested.contains("allowed.png"))
        #expect(!scheme.requested.contains("blocked.png"))
    }
    /// A file where the store keeps its rules, so WebKit really can't write them.
    @Test func aRefreshThatCantCompileKeepsTheLastGoodRules() async throws {
        let cache = try folder()
        let blocker = ContentBlocker(cacheDirectory: cache, bundledDirectory: try bothLists(), fetch: { [header] _ in header + "/new.png" })
        await blocker.prepare()
        let before = blocker.ruleLists
        try FileManager.default.removeItem(at: cache)
        try Data().write(to: cache)
        await blocker.refreshIfStale(now: later)
        #expect(zip(before, blocker.ruleLists).allSatisfy { $0 === $1 })
    }
    @Test func aListMissingFromTheBundleArrivesWithTheNextRefresh() async throws {
        let blocker = try blocker(bundled: listFolder("/blocked.png"), fetch: { [header] _ in header + "/new.png" })
        await blocker.prepare()
        #expect(blocker.ruleLists.count == 1)
        await blocker.refreshIfStale(now: .now)
        #expect(blocker.ruleLists.count == 2)
    }
    @Test func aRefreshReplacesTheRulesOnOpenTabs() async throws {
        let blocker = try blocker(bundled: bothLists("/old.png"), fetch: { [header] _ in header + "/new.png" })
        let (tab, scheme) = countedTab(profile(blockingWith: blocker))
        await blocker.prepare()
        await blocker.refreshIfStale(now: later)
        #expect(blocker.ruleLists.count == 2)
        await load("<img src='pobtest://x/old.png'><img src='pobtest://x/new.png'>", in: tab)
        #expect(scheme.requested.contains("old.png"))
        #expect(!scheme.requested.contains("new.png"))
    }
    @Test func theAppsRefreshReachesTheProfilesBlocker() async throws {
        var fetched = 0
        let profile = profile(blockingWith: try blocker(bundled: bothLists(), fetch: { [header] _ in fetched += 1; return header + "/new.png" }))
        await profile.contentBlocker.prepare()
        let app = AppController()
        app.profile = profile
        app.refreshFilterLists(now: later)
        #expect(await eventually { fetched == 2 })
    }
    /// A list with no date is due at once, so a refresh that came first would find nothing prepared and fetch nothing.
    @Test func theLaunchPreparesTheRulesThenRefreshes() async throws {
        var fetched = 0
        let profile = profile(blockingWith: try blocker(bundled: listFolder("/blocked.png"), fetch: { [header] _ in fetched += 1; return header + "/new.png" }))
        let app = AppController()
        app.profile = profile
        app.prepareFilterLists()
        #expect(await eventually { profile.contentBlocker.ruleLists.count == 2 })
        #expect(fetched == 1)
    }
    @Test func aHostedLaunchLeavesTheRealProfileAlone() {
        let app = AppController()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(app.profile == nil)
    }

    // MARK: Downloading

    private func configuration() -> URLSessionConfiguration {
        let configuration = ContentBlocker.downloadConfiguration()
        configuration.protocolClasses = [StubServer.self]
        return configuration
    }
    @Test func aDownloadReturnsTheText() async throws {
        let text = try await ContentBlocker.download(URL(string: "https://list.example/easylist.txt")!, configuration: configuration(), limit: 1_000)
        #expect(text == StubServer.good)
    }
    @Test func aDownloadOverTheLimitIsRefused() async throws {
        let url = URL(string: "https://list.example/easylist.txt")!
        await #expect(throws: URLError.self) {
            try await ContentBlocker.download(url, configuration: configuration(), limit: StubServer.good.utf8.count - 1)
        }
        _ = try await ContentBlocker.download(url, configuration: configuration(), limit: StubServer.good.utf8.count)
    }
    @Test func anErrorStatusIsRefused() async throws {
        await #expect(throws: URLError.self) {
            try await ContentBlocker.download(URL(string: "https://list.example/missing")!, configuration: configuration(), limit: 1_000)
        }
    }
    @Test func bytesThatArentTextAreRefused() async throws {
        await #expect(throws: URLError.self) {
            try await ContentBlocker.download(URL(string: "https://list.example/binary")!, configuration: configuration(), limit: 1_000)
        }
    }
    @Test func theDownloadKeepsNothingAndGivesUp() {
        let configuration = ContentBlocker.downloadConfiguration()
        #expect(configuration.timeoutIntervalForRequest <= 30)
        #expect(configuration.timeoutIntervalForResource <= 120)
        #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared)
        #expect(configuration.urlCache?.diskCapacity == 0)
        #expect(!configuration.waitsForConnectivity)
    }

    // MARK: Pages

    @Test func listedRequestsNeverLeaveEvenForTabsBuiltBeforeTheRules() async throws {
        let blocker = try blocker(bundled: listFolder("/blocked.png"))
        let scheme = CountingScheme()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "pobtest")
        blocker.attach(configuration.userContentController)
        await blocker.prepare()

        let tab = Tab(profile: .temporary(), configuration: configuration)
        await finishLoading(tab) {
            tab.webView.loadHTMLString("<img src='pobtest://x/blocked.png'><img src='pobtest://x/allowed.png'>", baseURL: URL(string: "pobtest://x/"))
        }
        #expect(scheme.requested.contains("allowed.png"))
        #expect(!scheme.requested.contains("blocked.png"))
    }
    @Test func aTabGetsRulesCompiledAfterItWasBuilt() async throws {
        let blocker = try blocker(bundled: listFolder("/blocked.png"))
        let (tab, scheme) = countedTab(profile(blockingWith: blocker))
        await blocker.prepare()
        await load(blockedAndAllowed, in: tab)
        #expect(scheme.requested.contains("allowed.png"))
        #expect(!scheme.requested.contains("blocked.png"))
    }
    @Test func aTabBuiltAfterTheRulesHasThem() async throws {
        let blocker = try blocker(bundled: listFolder("/blocked.png"))
        await blocker.prepare()
        let (tab, scheme) = countedTab(profile(blockingWith: blocker))
        await load(blockedAndAllowed, in: tab)
        #expect(scheme.requested.contains("allowed.png"))
        #expect(!scheme.requested.contains("blocked.png"))
    }
    /// Each add goes out to the web process, so an ordinary page load has to add nothing.
    @Test func aLoadOnAnOrdinarySiteSendsWebKitNothing() async throws {
        let blocker = try blocker(bundled: bothLists())
        await blocker.prepare()
        let controller = CountingController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let tab = Tab(profile: profile(blockingWith: blocker), configuration: configuration)
        #expect(controller.added == 2)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        #expect(controller.added == 2)
    }
    @Test func aClosedTabsControllerIsLetGo() async throws {
        let blocker = try blocker(bundled: bothLists())
        var controller: WKUserContentController? = WKUserContentController()
        weak let held = controller
        blocker.attach(try #require(controller))
        controller = nil
        #expect(await eventually { held == nil })
        await blocker.prepare()
        #expect(blocker.ruleLists.count == 2)
    }

    // MARK: Switching a site off

    @Test func aSiteSwitchedOffLoadsEverything() async throws {
        let profile = Profile.temporary()
        profile.contentBlocker = try blocker(bundled: listFolder("/blocked.png"))
        await profile.contentBlocker.prepare()
        profile.siteSettings["x"].adBlockerOff = true

        let scheme = CountingScheme()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "pobtest")
        let tab = Tab(profile: profile, configuration: configuration)
        await finishLoading(tab) {
            tab.webView.loadHTMLString("<img src='pobtest://x/blocked.png'>", baseURL: URL(string: "pobtest://x/"))
        }
        #expect(scheme.requested.contains("blocked.png"))
    }
    @Test func leavingASwitchedOffSiteBringsTheRulesBack() async throws {
        let profile = profile(blockingWith: try blocker(bundled: listFolder("/blocked.png")))
        await profile.contentBlocker.prepare()
        profile.siteSettings["x"].adBlockerOff = true
        let (tab, scheme) = countedTab(profile)
        await load("<p>x</p>", in: tab)
        #expect(try await askForBoth(in: tab, scheme))
        await load("<p>y</p>", in: tab, at: "pobtest://y/")
        #expect(try await !askForBoth(in: tab, scheme))
    }
    @Test func aSwitchedOffSiteStaysOffInARestoredSession() async throws {
        let profile = profile(blockingWith: try blocker(bundled: listFolder("/blocked.png")))
        await profile.contentBlocker.prepare()
        profile.siteSettings["x"].adBlockerOff = true
        let (saved, _) = countedTab(profile, page: blockedAndAllowed)
        await finishLoading(saved) { saved.webView.load(URLRequest(url: URL(string: "pobtest://x/")!)) }
        let state = try #require(saved.webView.interactionState)

        let (restored, scheme) = countedTab(profile, page: blockedAndAllowed)
        await finishLoading(restored) { restored.webView.interactionState = state }
        #expect(scheme.requested.contains("blocked.png"))
        #expect(restored.webView.url?.host() == "x")
    }
    /// A restored page and the first rules race at launch, and a page that lost must still be left alone.
    @Test func rulesArrivingLateLeaveASwitchedOffPageAlone() async throws {
        let blocker = try blocker(bundled: bothLists())
        let profile = profile(blockingWith: blocker)
        profile.siteSettings["x"].adBlockerOff = true
        let (tab, scheme) = countedTab(profile)
        await load("<p>x</p>", in: tab)
        await blocker.prepare()
        #expect(try await askForBoth(in: tab, scheme))
    }
    @Test func aRefreshLeavesASwitchedOffPageAlone() async throws {
        let blocker = try blocker(bundled: bothLists(), fetch: { [header] _ in header + "/blocked.png" })
        let profile = profile(blockingWith: blocker)
        await blocker.prepare()
        profile.siteSettings["x"].adBlockerOff = true
        let (tab, scheme) = countedTab(profile)
        await load("<p>x</p>", in: tab)
        await blocker.refreshIfStale(now: later)
        #expect(try await askForBoth(in: tab, scheme))
    }
    /// Only a load that's really going ahead changes what's on the page. The last action shows the others could have.
    @Test func onlyAMainFrameLoadChangesTheRules() async throws {
        let profile = profile(blockingWith: try blocker(bundled: listFolder("/blocked.png")))
        await profile.contentBlocker.prepare()
        profile.siteSettings["off.example"].adBlockerOff = true
        let (tab, scheme) = countedTab(profile)
        tab.appToOpen = { _ in nil }
        await load("<p>x</p>", in: tab)
        let off = URL(string: "https://off.example/page")!
        let elsewhere: [FakeNavigationAction] = [
            FakeNavigationAction(url: off, type: .linkActivated, modifiers: [], shouldDownload: true, target: FakeMainFrame()),
            FakeNavigationAction(url: URL(string: "msteams://off.example/join")!, type: .linkActivated, modifiers: [], target: FakeMainFrame()),
            FakeNavigationAction(url: off, type: .linkActivated, modifiers: .command, target: FakeMainFrame()),
            FakeNavigationAction(url: off, type: .linkActivated, modifiers: [], target: nil),
        ]
        for action in elsewhere {
            tab.webView(tab.webView, decidePolicyFor: action) { _ in }
            #expect(try await !askForBoth(in: tab, scheme))
        }
        tab.webView(tab.webView, decidePolicyFor: FakeNavigationAction(url: off, type: .linkActivated, modifiers: [], target: FakeMainFrame())) { _ in }
        #expect(try await askForBoth(in: tab, scheme))
    }
    /// A link that turns out to be an attachment leaves the page where it is, and that page keeps its own site's rules.
    @Test func aLinkThatTurnsOutToBeAnAttachmentChangesNothing() async throws {
        let profile = profile(blockingWith: try blocker(bundled: listFolder("/blocked.png")))
        await profile.contentBlocker.prepare()
        profile.siteSettings["off.example"].adBlockerOff = true
        let (tab, scheme) = countedTab(profile, page: "<p>x</p>")
        await open(tab)
        func click(_ url: URL) {
            tab.webView(tab.webView, decidePolicyFor: FakeNavigationAction(url: url, type: .linkActivated, modifiers: [], target: FakeMainFrame())) { _ in }
            tab.webView(tab.webView, decidePolicyFor: FakeAttachment(url: url)) { #expect($0 == .download) }
        }
        click(URL(string: "https://off.example/report.pdf")!)
        #expect(try await !askForBoth(in: tab, scheme))

        profile.siteSettings["x"].adBlockerOff = true
        await open(tab)
        click(URL(string: "https://on.example/report.pdf")!)
        #expect(try await askForBoth(in: tab, scheme))
    }
    /// A frame's site isn't the page's site, so an embed can't turn the rules off.
    @Test func aSwitchedOffSiteInAFrameLeavesThePageBlocked() async throws {
        let profile = profile(blockingWith: try blocker(bundled: listFolder("/blocked.png")))
        await profile.contentBlocker.prepare()
        profile.siteSettings["off.example"].adBlockerOff = true
        let (tab, scheme) = countedTab(profile)
        await load("<iframe src='pobtest://off.example/frame'></iframe>", in: tab)
        #expect(scheme.requested.contains("frame"))
        #expect(try await !askForBoth(in: tab, scheme))
    }
    /// WebKit hands a popup its opener's controller, and a shared one would turn one tab's rules off for the other.
    @Test func aPopupSwitchesItsRulesOnItsOwn() async throws {
        let blocker = try blocker(bundled: listFolder("/blocked.png"))
        await blocker.prepare()
        let (controller, opener, scheme) = try window(blockingWith: blocker, page: "<p>page</p>")
        opener.profile.siteSettings["off.example"].adBlockerOff = true
        await open(opener)

        #expect(try await opener.webView.evaluateJavaScript("window.open('pobtest://off.example/') !== null") as? Bool == true)
        #expect(await eventually { controller.tab !== opener })
        let popup = try #require(controller.tab)
        #expect(await eventually { popup.webView.url?.host() == "off.example" && !popup.webView.isLoading })
        #expect(try await popup.webView.evaluateJavaScript("window.opener !== null") as? Bool == true)

        #expect(try await askForBoth(in: popup, scheme))
        #expect(try await !askForBoth(in: opener, scheme))
    }

    /// A rule with no type covers the page itself, so a link to a listed host lands here. The error page sits at the
    /// blocked address, where it mustn't be blocked in turn, and the switch is the way through.
    @Test func aPageTheRulesBlockShowsAnErrorAndTheSwitchLetsItThrough() async throws {
        let blocker = try blocker(bundled: listFolder("||blocked.example^"))
        await blocker.prepare()
        let (controller, tab, scheme) = try window(blockingWith: blocker, page: "<title>Real</title>")
        await finishLoading(tab) { tab.load(.url(URL(string: "pobtest://blocked.example/")!)) }
        #expect(tab.isShowingErrorPage)
        #expect(await eventually { tab.title == "pob blocked blocked.example" })
        #expect(tab.webView.url?.host() == "blocked.example")
        #expect(scheme.requested.isEmpty)

        await finishLoading(tab) { controller.perform(.toggleSiteBlocking) }
        #expect(!tab.isShowingErrorPage)
        #expect(scheme.requested == ["/"])
        #expect(await eventually { tab.title == "Real" })
    }

    // MARK: Load anyway

    /// The blocked page, with its link clicked.
    func loadAnyway(_ tab: Tab) async {
        await finishLoading(tab) { tab.load(.url(URL(string: "pobtest://blocked.example/")!)) }
        await finishLoading(tab) { tab.webView.evaluateJavaScript("document.querySelector('a').click()", completionHandler: nil) }
    }
    @Test func loadAnywayOpensABlockedPageOnce() async throws {
        let blocker = try blocker(bundled: listFolder("||blocked.example^"))
        await blocker.prepare()
        let (_, tab, scheme) = try window(blockingWith: blocker, page: "<title>Real</title>")
        await finishLoading(tab) { tab.load(.url(URL(string: "pobtest://blocked.example/")!)) }
        #expect(await eventually { tab.title == "pob blocked blocked.example" })
        #expect(tab.isShowingBlockedPage)
        await finishLoading(tab) { tab.webView.evaluateJavaScript("document.querySelector('a').click()", completionHandler: nil) }
        #expect(await eventually { tab.title == "Real" })
        #expect(!tab.isShowingBlockedPage)
        #expect(tab.unblockedHost == "blocked.example")
        #expect(scheme.requested == ["/"])
        #expect(tab.profile.siteSettings["blocked.example"] == SiteSetting()) // nothing remembered
    }
    @Test func loadAnywayEndsWhenTheTabLeavesTheSite() async throws {
        let blocker = try blocker(bundled: listFolder("||blocked.example^\n/blocked.png"))
        await blocker.prepare()
        let (_, tab, scheme) = try window(blockingWith: blocker, page: "<title>Real</title>")
        await loadAnyway(tab)
        #expect(try await askForBoth(in: tab, scheme)) // the page let through runs without the rules

        let earlier = scheme.requested.count
        await load(blockedAndAllowed, in: tab, at: "pobtest://other.example/")
        #expect(tab.unblockedHost == nil)
        #expect(scheme.requested.dropFirst(earlier).contains("allowed.png"))
        #expect(!scheme.requested.dropFirst(earlier).contains("blocked.png"))

        await finishLoading(tab) { tab.load(.url(URL(string: "pobtest://blocked.example/")!)) }
        #expect(await eventually { tab.title == "pob blocked blocked.example" })
        #expect(tab.isShowingBlockedPage)
    }
    /// The page it stays on is still the one let through, so a download link leaves its rules off.
    @Test func aDownloadLinkLeavesAPageLetThroughAlone() async throws {
        let blocker = try blocker(bundled: listFolder("||blocked.example^\n/blocked.png"))
        await blocker.prepare()
        let (_, tab, scheme) = try window(blockingWith: blocker, page: "<title>Real</title>")
        await loadAnyway(tab)
        let file = URL(string: "https://elsewhere.example/report.pdf")!
        tab.webView(tab.webView, decidePolicyFor: FakeNavigationAction(url: file, type: .linkActivated, modifiers: [], target: FakeMainFrame())) { _ in }
        tab.webView(tab.webView, decidePolicyFor: FakeAttachment(url: file)) { #expect($0 == .download) }
        #expect(try await askForBoth(in: tab, scheme))
    }
    @Test func aPageCantUseTheLinkItself() async throws {
        let blocker = try blocker(bundled: listFolder("/blocked.png"))
        await blocker.prepare()
        let (_, tab, scheme) = try window(blockingWith: blocker, page: "<a href='pob:load-anyway'>Load anyway</a>")
        var offered = false
        tab.appToOpen = { _ in
            offered = true
            return nil
        }
        await open(tab)
        let loads = scheme.requested.count
        var loaded = false
        tab.onLoadFinished = { loaded = true }
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('a').click(); true")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!loaded)
        #expect(!offered)
        #expect(scheme.requested.count == loads)
        #expect(tab.unblockedHost == nil)
        #expect(try await !askForBoth(in: tab, scheme))
    }
    /// Once the site's switch is used it decides, so switching blocking back on blocks the page again.
    @Test func theSiteSwitchTakesOverFromLoadAnyway() async throws {
        let blocker = try blocker(bundled: listFolder("||blocked.example^"))
        await blocker.prepare()
        let (controller, tab, _) = try window(blockingWith: blocker, page: "<title>Real</title>")
        await loadAnyway(tab)
        await finishLoading(tab) { controller.perform(.toggleSiteBlocking) }
        #expect(tab.profile.siteSettings["blocked.example"].adBlockerOff == true)
        #expect(await eventually { tab.title == "Real" })
        await finishLoading(tab) { controller.perform(.toggleSiteBlocking) }
        #expect(await eventually { tab.title == "pob blocked blocked.example" })
        #expect(tab.isShowingBlockedPage)
    }
    @Test func otherErrorsKeepTheirRetry() {
        #expect(ErrorPage.html(for: URL(string: "https://x.example/")!, error: URLError(.timedOut)).contains(">Retry<"))
        #expect(!ErrorPage.blockedHTML(for: URL(string: "https://x.example/")!).contains("Retry"))
    }

    // MARK: The command

    /// A window whose active tab counts its requests. A popup is the way in for a tab with a scheme of its own.
    func window(blockingWith blocker: ContentBlocker, page: String) throws -> (controller: WindowController, tab: Tab, scheme: CountingScheme) {
        let tabs = TabManager(profile: profile(blockingWith: blocker), keepsSpare: false)
        let scheme = CountingScheme()
        scheme.page = page
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "pobtest")
        _ = tabs.newTab(nil, activate: true).onCreatePopup?(configuration)
        let settings = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let controller = WindowController(appearance: AppearanceModel(store: SettingsStore(fileURL: settings), reduceTransparency: false), tabs: tabs)
        return (controller, try #require(tabs.activeTab), scheme)
    }
    @Test func theCommandSwitchesTheSiteOffAndBackOnAndReloads() async throws {
        let blocker = try blocker(bundled: listFolder("/blocked.png"))
        await blocker.prepare()
        let (controller, tab, scheme) = try window(blockingWith: blocker, page: blockedAndAllowed)
        await open(tab)
        #expect(scheme.requested.contains("allowed.png"))
        #expect(!scheme.requested.contains("blocked.png"))

        await finishLoading(tab) { controller.perform(.toggleSiteBlocking) }
        #expect(tab.profile.siteSettings["x"].adBlockerOff == true)
        #expect(scheme.requested.contains("blocked.png"))

        let asked = scheme.requested.count
        await finishLoading(tab) { controller.perform(.toggleSiteBlocking) }
        #expect(tab.profile.siteSettings["x"] == SiteSetting()) // on is the default, so it leaves nothing in sites.json
        #expect(scheme.requested.dropFirst(asked).contains("allowed.png"))
        #expect(!scheme.requested.dropFirst(asked).contains("blocked.png"))
    }
    @Test func theSwitchIsKeptForTheNextTabAndTheNextLaunch() async throws {
        let blocker = try blocker(bundled: listFolder("/blocked.png"))
        await blocker.prepare()
        let (controller, tab, _) = try window(blockingWith: blocker, page: "<p>x</p>")
        await open(tab)
        await finishLoading(tab) { controller.perform(.toggleSiteBlocking) }

        let (next, scheme) = countedTab(tab.profile)
        await load(blockedAndAllowed, in: next)
        #expect(scheme.requested.contains("blocked.png"))
        let reopened = SiteSettings(file: JSONFile(url: tab.profile.directory.appending(path: "sites.json")))
        #expect(reopened["x"].adBlockerOff == true)
    }
    @Test func theCommandDoesNothingWithNoTab() {
        let profile = Profile.temporary()
        let settings = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let controller = WindowController(appearance: AppearanceModel(store: SettingsStore(fileURL: settings), reduceTransparency: false), tabs: TabManager(profile: profile, keepsSpare: false))
        controller.perform(.toggleSiteBlocking)
        #expect(!FileManager.default.fileExists(atPath: profile.directory.appending(path: "sites.json").path()))
    }
    @Test func theCommandDoesNothingOnAPageWithNoHost() async throws {
        let (controller, tab, scheme) = try window(blockingWith: blocker(bundled: bothLists()), page: "<p>x</p>")
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: nil) }
        let loads = scheme.requested.count
        var reloaded = false
        tab.onLoadFinished = { reloaded = true }
        controller.perform(.toggleSiteBlocking)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!reloaded)
        #expect(scheme.requested.count == loads)
        #expect(!FileManager.default.fileExists(atPath: tab.profile.directory.appending(path: "sites.json").path()))
    }
    @Test func theCommandHasNoShortcutAndShowsInTheSwitcher() {
        let list = CommandList.standard { _ in }
        #expect(list.command(.toggleSiteBlocking)?.title == "Toggle Ad Blocking for This Site")
        #expect(list.command(.toggleSiteBlocking)?.key == "")
        let rows = SwitcherModel.rows(query: "ad blocking", tabs: [], bookmarks: [], history: [], commands: list.all)
        #expect(rows.contains { $0.target == .command(.toggleSiteBlocking) })
    }
}
