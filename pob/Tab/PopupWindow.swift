import AppKit
import WebKit

/// A plain window for script-opened popups, so sign-in flows keep their link to the opener.
final class PopupWindow: NSWindowController, NSWindowDelegate {
    private static var openWindows: Set<PopupWindow> = []

    private let webView: WKWebView

    static func open(
        configuration: WKWebViewConfiguration,
        features: WKWindowFeatures,
        uiDelegate: WKUIDelegate
    ) -> WKWebView {
        let size = NSSize(
            width: features.width?.doubleValue ?? 520,
            height: features.height?.doubleValue ?? 680
        )
        let popup = PopupWindow(configuration: configuration, size: size)
        popup.webView.uiDelegate = uiDelegate
        openWindows.insert(popup)
        popup.showWindow(nil)
        return popup.webView
    }

    /// Closes the popup showing this web view. Does nothing for other web views.
    static func close(showing webView: WKWebView) {
        openWindows.first { $0.webView === webView }?.close()
    }

    private init(configuration: WKWebViewConfiguration, size: NSSize) {
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        webView.isInspectable = true
        webView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        Self.openWindows.remove(self)
    }
}
