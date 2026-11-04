import Foundation
import Testing
@testable import pob

@Suite struct DevToolsTests {
    @Test func blankPagesDontOpenInSafari() async {
        let tab = Tab(profile: .initial)
        await withCheckedContinuation { continuation in
            tab.onLoadFinished = { tab.onLoadFinished = nil; continuation.resume() }
            tab.load(.url(URL(string: "about:blank")!))
        }
        #expect(tab.safariURL == nil)
    }
    @Test func realPagesOpenInSafari() async {
        let tab = Tab(profile: .initial)
        await withCheckedContinuation { continuation in
            tab.onLoadFinished = { tab.onLoadFinished = nil; continuation.resume() }
            tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/page"))
        }
        #expect(tab.safariURL?.absoluteString == "https://localhost/page")
    }
}
