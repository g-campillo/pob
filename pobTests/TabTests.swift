import Foundation
import Testing
import WebKit
@testable import pob

@Suite struct TabTests {
    func tabWith(html: String) async -> Tab {
        let tab = Tab(profile: .initial)
        await withCheckedContinuation { continuation in
            tab.onLoadFinished = { tab.onLoadFinished = nil; continuation.resume() }
            tab.webView.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))
        }
        return tab
    }

    @Test func userAgentUsesInstalledSafariVersion() throws {
        let plist = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".plist")
        try (["CFBundleShortVersionString": "27.1"] as NSDictionary).write(to: plist)
        #expect(UserAgent.applicationName(safariInfoPlist: plist) == "Version/27.1 Safari/605.1.15")
    }
    @Test func missingSafariFallsBack() {
        let plist = URL(fileURLWithPath: "/nonexistent.plist")
        #expect(UserAgent.applicationName(safariInfoPlist: plist) == UserAgent.fallback)
    }
    @Test func pagesSeeSafari() async throws {
        let tab = await tabWith(html: "<p>x</p>")
        let agent = try await tab.webView.evaluateJavaScript("navigator.userAgent") as? String
        #expect(agent?.contains("Version/") == true && agent?.contains("Safari/") == true)
    }
    @Test func h264AndAACAreSupported() async throws {
        let tab = await tabWith(html: "<p>x</p>")
        let result = try await tab.webView.evaluateJavaScript("document.createElement('video').canPlayType('video/mp4; codecs=\"avc1.42E01E, mp4a.40.2\"')") as? String
        #expect(result == "probably")
    }
    @Test func screenCaptureIsExposed() async throws {
        let tab = await tabWith(html: "<p>x</p>")
        let result = try await tab.webView.evaluateJavaScript("typeof navigator.mediaDevices?.getDisplayMedia") as? String
        #expect(result == "function")
    }
    @Test func linksStayInTheTabAndScriptsGetPopups() {
        #expect(Tab.popupPolicy(for: .linkActivated) == .sameTab)
        #expect(Tab.popupPolicy(for: .other) == .popupWindow)
    }
    @Test func promptNamesTheSiteAndDevice() {
        #expect(Permissions.promptText(host: "meet.example.com", type: .camera) == "Allow meet.example.com to use your camera?")
        #expect(Permissions.promptText(host: "meet.example.com", type: .microphone) == "Allow meet.example.com to use your microphone?")
        #expect(Permissions.promptText(host: "meet.example.com", type: .cameraAndMicrophone) == "Allow meet.example.com to use your camera and microphone?")
    }
}
