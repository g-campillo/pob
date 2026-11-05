import AppKit
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

/// A one-pixel PNG, as the page's icon or as what `FaviconStore` keeps on disk.
let tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNg+P8fAAADAQH/VcGg6AAAAABJRU5ErkJggg=="

func writeIcon(forHost host: String, in folder: URL) throws {
    try Data(base64Encoded: tinyPNG)?.write(to: folder.appending(path: FaviconStore.fileName(forHost: host)))
}

/// What a table says to a screen reader, row by row. Its rows are AppKit's stand-ins, which answer only the old attribute call,
/// and walking them is the point: a label on a view that isn't in this tree reads back fine and reaches no one.
func accessibleRows(of table: NSTableView) -> [(label: String?, isSelected: Bool)] {
    func value(_ attribute: NSAccessibility.Attribute, of element: Any?) -> Any? {
        (element as? NSObject)?.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute.rawValue)?.takeUnretainedValue()
    }
    return (value(.rows, of: table) as? [Any] ?? []).map { row in
        let cell = (value(.children, of: row) as? [Any])?.first
        return (value(.description, of: cell) as? String, value(.selected, of: row) as? Bool == true)
    }
}

/// Polls for up to a second.
func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private final class ModalWatch {
    var sawModal = false
}

/// Runs `body` and reports whether a dialog went modal during it. It ends any that does, or the run would hang.
func wentModal(during body: () async throws -> Void) async rethrows -> Bool {
    let watch = ModalWatch()
    let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
        MainActor.assumeIsolated {
            guard NSApp.modalWindow != nil else { return }
            watch.sawModal = true
            NSApp.abortModal()
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    defer { timer.invalidate() }
    try await body()
    return watch.sawModal
}
