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

/// Runs `body` with animations forced on or off, then puts the real switches back. A test run has them off.
/// `body` can't wait on anything, or another test would run with these switches.
func withMotion(_ style: MotionStyle, reduced: Bool = false, _ body: () throws -> Void) rethrows {
    let (oldStyle, oldReduced) = (Motion.style, Motion.reducesMotion)
    defer { (Motion.style, Motion.reducesMotion) = (oldStyle, oldReduced) }
    Motion.style = { style }
    Motion.reducesMotion = { reduced }
    try body()
}

func pointerEvent(_ type: NSEvent.EventType) -> NSEvent {
    NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
}

/// An `AppearanceModel` over a settings file of its own.
func testAppearance() -> AppearanceModel {
    AppearanceModel(store: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")), reduceTransparency: false)
}

/// Runs the item with this title as choosing it would. False when the menu has none.
@discardableResult
func choose(_ title: String, in menu: NSMenu) -> Bool {
    let index = menu.indexOfItem(withTitle: title)
    guard index >= 0 else { return false }
    menu.performActionForItem(at: index)
    return true
}
