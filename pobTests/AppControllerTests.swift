import AppKit
import Testing
@testable import pob

@Suite struct AppControllerTests {
    @Test func hostedTestsSkipWindowSetup() {
        #expect(AppController.isRunningTests)
    }
    /// With a mouse attached, macOS gives every scroll bar a gutter of its own beside the page. The test host
    /// starts the way pob does, so what `main` asked for holds here.
    @Test func scrollBarsFloatOverThePageAndShowOnlyWhileScrolling() {
        #expect(UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["AppleShowScrollBars"] as? String == "WhenScrolling")
    }
}
