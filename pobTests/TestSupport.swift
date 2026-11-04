import Foundation
@testable import pob

/// Runs `start` and returns once the tab reports a finished load. Any earlier `onLoadFinished` still fires and is put back.
func finishLoading(_ tab: Tab, _ start: () -> Void) async {
    let previous = tab.onLoadFinished
    await withCheckedContinuation { continuation in
        tab.onLoadFinished = {
            previous?()
            continuation.resume()
        }
        start()
    }
    tab.onLoadFinished = previous
}

func tabWith(html: String) async -> Tab {
    let tab = Tab(profile: .temporary())
    await finishLoading(tab) { tab.webView.loadHTMLString(html, baseURL: URL(string: "https://localhost/")) }
    return tab
}

/// Polls for up to a second.
func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
