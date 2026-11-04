import AppKit
import WebKit

/// The only file allowed to use private APIs. Every call reports failure instead of crashing,
/// so callers can fall back when a macOS update removes one.
enum PrivateAPI {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetBlurRadius = @convention(c) (Int32, Int, Int32) -> Int32

    private static let inspectorSelectors = [
        "show", "close", "attach", "showConsole", "isVisible", "showMainResourceForFrame:",
    ]

    static func setWindowBlur(_ window: NSWindow, radius: Int) -> Bool {
        let allImages = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connectionSymbol = dlsym(allImages, "CGSDefaultConnectionForThread"),
              let blurSymbol = dlsym(allImages, "CGSSetWindowBackgroundBlurRadius")
        else { return false }
        let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
        let setRadius = unsafeBitCast(blurSymbol, to: SetBlurRadius.self)
        return setRadius(connection, window.windowNumber, Int32(radius)) == 0
    }

    static func setDrawsBackground(_ webView: WKWebView, _ draws: Bool) {
        webView.setValue(draws, forKey: "drawsBackground")
    }

    static func drawsBackground(_ webView: WKWebView) -> Bool {
        webView.value(forKey: "drawsBackground") as? Bool ?? true
    }

    static func enableDeveloperExtras(_ configuration: WKWebViewConfiguration) {
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    }

    static func showInspector(_ webView: WKWebView) -> Bool {
        performOnInspector("show", of: webView) && performOnInspector("attach", of: webView)
    }

    static func closeInspector(_ webView: WKWebView) -> Bool {
        performOnInspector("close", of: webView)
    }

    static func isInspectorVisible(_ webView: WKWebView) -> Bool {
        inspector(of: webView)?.value(forKey: "isVisible") as? Bool ?? false
    }

    static func showConsole(_ webView: WKWebView) -> Bool {
        performOnInspector("showConsole", of: webView) && performOnInspector("attach", of: webView)
    }

    static func showPageSource(_ webView: WKWebView) -> Bool {
        let mainFrame = NSSelectorFromString("_mainFrame")
        guard webView.responds(to: mainFrame),
              let frame = webView.perform(mainFrame)?.takeUnretainedValue()
        else { return false }
        return performOnInspector("showMainResourceForFrame:", of: webView, with: frame)
            && performOnInspector("attach", of: webView)
    }

    static func missingSelectors(on webView: WKWebView) -> [String] {
        var missing = ["_inspector", "_mainFrame"].filter { !webView.responds(to: NSSelectorFromString($0)) }
        let inspector = inspector(of: webView)
        missing += inspectorSelectors.filter { inspector?.responds(to: NSSelectorFromString($0)) != true }
        return missing
    }

    private static func inspector(of webView: WKWebView) -> NSObject? {
        guard webView.responds(to: NSSelectorFromString("_inspector")) else { return nil }
        return webView.value(forKey: "_inspector") as? NSObject
    }

    private static func performOnInspector(_ name: String, of webView: WKWebView, with argument: Any? = nil) -> Bool {
        let selector = NSSelectorFromString(name)
        guard let inspector = inspector(of: webView), inspector.responds(to: selector) else { return false }
        _ = inspector.perform(selector, with: argument)
        return true
    }
}

/// iTerm2 found that blur can break for good once it's set from above 0 back to exactly 0,
/// so after the first use this never sends less than 1.
struct BlurGate {
    private var hasBeenUsed = false

    mutating func radiusToSend(_ requested: Int) -> Int {
        if requested > 0 {
            hasBeenUsed = true
            return requested
        }
        return hasBeenUsed ? 1 : 0
    }
}
