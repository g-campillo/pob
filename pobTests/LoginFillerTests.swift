import AppKit
import Foundation
import Testing
import WebKit
@testable import pob

@Suite struct LoginFillerTests {
    func tabWith(html: String) async -> Tab {
        let tab = Tab(profile: .initial)
        await withCheckedContinuation { continuation in
            tab.onLoadFinished = { tab.onLoadFinished = nil; continuation.resume() }
            tab.webView.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))
        }
        return tab
    }

    @Test func fillsPasswordsWithSpecialCharacters() async throws {
        let tab = await tabWith(html: "<form><input id=u type=email><input id=p type=password></form>")
        let password = "q\"'\\<>é"
        #expect(try await LoginFiller.fill(tab.webView, username: "a@b.c", password: password))
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('u').value") as? String == "a@b.c")
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('p').value") as? String == password)
    }
    @Test func firesInputEventsSoWebAppsNotice() async throws {
        let tab = await tabWith(html: "<input id=u type=text><input id=p type=password><script>window.n=0;p.addEventListener('input',()=>window.n++)</script>")
        _ = try await LoginFiller.fill(tab.webView, username: "a", password: "b")
        #expect(try await tab.webView.evaluateJavaScript("window.n") as? Int == 1)
    }
    @Test func reportsWhenThereIsNoLoginForm() async throws {
        let tab = await tabWith(html: "<p>nothing here</p>")
        #expect(try await LoginFiller.fill(tab.webView, username: "a", password: "b") == false)
    }
    @Test func fieldsUseAutoFillContentTypes() {
        let popover = SignInPopover(host: "example.com") { _, _ in }
        popover.loadView()
        #expect(popover.usernameField.contentType == .username)
        #expect(popover.passwordField.contentType == .password)
    }
}
