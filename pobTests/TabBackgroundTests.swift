import Foundation
import Testing
@testable import pob

/// The blank page shows the blurred desktop, but a real page with no background of its own
/// must still get a normal one, or its text would sit straight on the desktop.
@Suite struct TabBackgroundTests {
    @Test func blankPageStaysClear() async {
        let tab = Tab(profile: .temporary())
        await finishLoading(tab) { tab.load(.url(URL(string: "about:blank")!)) }
        #expect(PrivateAPI.drawsBackground(tab.webView) == false)
    }

    @Test func realPagesGetANormalBackground() async {
        let tab = Tab(profile: .temporary())
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        #expect(PrivateAPI.drawsBackground(tab.webView) == true)
    }

    @Test func goingBackToBlankClearsItAgain() async {
        let tab = Tab(profile: .temporary())
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        await finishLoading(tab) { tab.load(.url(URL(string: "about:blank")!)) }
        #expect(PrivateAPI.drawsBackground(tab.webView) == false)
    }
}
