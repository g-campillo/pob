import AppKit
import Testing
import WebKit
@testable import pob

@Suite struct PrivateAPITests {
    @Test func blurWorksOnARealWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        #expect(PrivateAPI.setWindowBlur(window, radius: 10))
    }
    @Test func inspectorAPIsStillExist() {
        let configuration = WKWebViewConfiguration()
        PrivateAPI.enableDeveloperExtras(configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #expect(PrivateAPI.missingSelectors(on: webView).isEmpty)
    }
    @Test func blurNeverReturnsToZeroOnceUsed() {
        var gate = BlurGate()
        #expect(gate.radiusToSend(0) == 0)
        #expect(gate.radiusToSend(16) == 16)
        #expect(gate.radiusToSend(0) == 1)
        #expect(gate.radiusToSend(8) == 8)
    }

    @Test func unknownPrivateKeysAreSkippedInsteadOfCrashing() {
        #expect(PrivateAPI.setValue(true, forKey: "madeUpKey", setter: "_setMadeUpKey:", on: NSObject()) == false)
    }
}
