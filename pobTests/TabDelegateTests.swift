import Foundation
import Testing
@testable import pob

/// A delegate method whose Swift signature drifts from WebKit's compiles fine but is never called,
/// so check that each one is really visible to WebKit.
@Suite struct TabDelegateTests {
    @Test(arguments: [
        "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
        "webViewDidClose:",
        "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
        "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
        "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
        "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
        "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
        "webView:didFinishNavigation:",
        "webView:decidePolicyForNavigationAction:decisionHandler:",
        "webView:didFailProvisionalNavigation:withError:",
        "webView:didFailNavigation:withError:",
        "webViewWebContentProcessDidTerminate:",
        "webView:didReceiveAuthenticationChallenge:completionHandler:",
        "webView:decidePolicyForNavigationResponse:decisionHandler:",
        "webView:navigationAction:didBecomeDownload:",
        "webView:navigationResponse:didBecomeDownload:",
    ])
    func webKitCanReachDelegateMethod(selector: String) {
        #expect(Tab(profile: .temporary()).responds(to: NSSelectorFromString(selector)))
    }
}
