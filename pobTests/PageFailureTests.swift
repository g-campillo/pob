import Foundation
import Testing
@testable import pob

@Suite struct PageFailureTests {
    let page = URL(string: "https://example.com/a")!

    @Test func errorPagesNameTheFailure() {
        let error = URLError(.notConnectedToInternet)
        #expect(ErrorPage.html(for: page, error: error).contains("example.com"))
    }
    @Test func errorTextCantInjectMarkup() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "<script>alert(1)</script>"])
        let html = ErrorPage.html(for: page, error: error)
        #expect(!html.contains("<script>alert"))
        #expect(html.contains("&lt;script&gt;alert"))
    }
    @Test func retryLinksAreEscapedAndLimitedToWebAndFileAddresses() {
        let error = URLError(.timedOut)
        let quoted = URL(string: "https://example.com/a?x=%22onmouseover=%22")!
        #expect(!ErrorPage.html(for: URL(string: "https://e.com/\"x")!, error: error).contains("\"x\""))
        #expect(ErrorPage.html(for: quoted, error: error).contains("Retry"))
        #expect(!ErrorPage.html(for: URL(string: "javascript:alert(1)")!, error: error).contains("<a "))
        #expect(!ErrorPage.crashHTML(for: nil).contains("<a "))
        #expect(ErrorPage.crashHTML(for: page).contains("Reload"))
    }
    @Test func cancelledLoadsShowNothing() {
        #expect(!ErrorPage.shouldShow(URLError(.cancelled)))
        #expect(!ErrorPage.shouldShow(NSError(domain: "WebKitErrorDomain", code: 102)))
        #expect(ErrorPage.shouldShow(URLError(.timedOut)))
    }
    @Test func challengesGetTheRightResponse() {
        let cases: [(String, Bool, Bool, ChallengeAction)] = [
            (NSURLAuthenticationMethodHTTPBasic, false, true, .askForPassword),
            (NSURLAuthenticationMethodHTTPDigest, false, true, .askForPassword),
            (NSURLAuthenticationMethodServerTrust, false, true, .useDefault),
            (NSURLAuthenticationMethodServerTrust, false, false, .askAboutCertificate),
            (NSURLAuthenticationMethodServerTrust, true, false, .trust),
            (NSURLAuthenticationMethodClientCertificate, false, true, .useDefault),
        ]
        for (method, allowed, valid, expected) in cases {
            #expect(SignInChallenge.action(method: method, hostIsAllowed: allowed, trustIsValid: valid) == expected)
        }
    }
    @Test func aSecondCrashWithinTenSecondsGivesUp() {
        var recovery = CrashRecovery()
        let start = Date(timeIntervalSince1970: 1000)
        let first = recovery.shouldReload(at: start)
        let second = recovery.shouldReload(at: start.addingTimeInterval(9))
        let third = recovery.shouldReload(at: start.addingTimeInterval(11))
        #expect(first && !second && third)
    }
    @Test func aLoadThatFailsShowsTheErrorPageAndLeavesNoHistory() async {
        let profile = Profile.temporary()
        let tabs = TabManager(profile: profile, keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.load(.url(URL(string: "http://localhost:1/")!)) }
        #expect(tab.isShowingErrorPage)
        let text = try? await tab.webView.evaluateJavaScript("document.body.innerText") as? String
        #expect(text?.contains("localhost") == true)
        try? await Task.sleep(for: .milliseconds(200))
        let found = await profile.history.search("localhost", limit: 5)
        #expect(found.isEmpty)
        #expect(tabs.snapshotRecords[0].url?.host() == "localhost")
        #expect(tabs.snapshotRecords[0].interactionState == nil)
    }
}
