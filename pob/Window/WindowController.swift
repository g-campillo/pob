import AppKit
import WebKit

final class WindowController: NSWindowController {
    let tab: Tab
    private(set) var usesFallbackBlur = false

    private let appearance: AppearanceModel
    private let contentView = NSView()
    private var blurGate = BlurGate()
    private var fallbackBlurView: NSVisualEffectView?

    init(appearance: AppearanceModel, tab: Tab) {
        self.appearance = appearance
        self.tab = tab

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.hasShadow = true
        window.minSize = NSSize(width: 480, height: 360)
        window.center()
        super.init(window: window)

        buildContent(in: window)
        setWindowButtonsVisible(false)
        appearance.onChange = { [weak self] in self?.applyAppearance() }
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func applyAppearance() {
        guard let window else { return }
        let effective = appearance.effective
        tab.webView.alphaValue = effective.pageAlpha

        if !PrivateAPI.setWindowBlur(window, radius: blurGate.radiusToSend(effective.blurRadius)) {
            installFallbackBlur()
        }
        fallbackBlurView?.isHidden = effective.blurRadius == 0
        window.invalidateShadow()
    }

    func perform(_ id: CommandID) {
        switch id {
        case .back: tab.webView.goBack()
        case .forward: tab.webView.goForward()
        case .reload: tab.webView.reload()
        case .snapOpaque: appearance.toggleSnap()
        case .closeWindow: window?.performClose(nil)
        default: break
        }
    }

    func setWindowButtonsVisible(_ visible: Bool) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(button)?.isHidden = !visible
        }
    }

    private func buildContent(in window: NSWindow) {
        window.contentView = contentView

        let webView = tab.webView
        webView.frame = contentView.bounds
        webView.autoresizingMask = [.width, .height]
        contentView.addSubview(webView)

        let strip = TopDragStrip(frame: NSRect(
            x: 0,
            y: contentView.bounds.height - TopDragStrip.height,
            width: contentView.bounds.width,
            height: TopDragStrip.height
        ))
        strip.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(strip)
    }

    private func installFallbackBlur() {
        guard fallbackBlurView == nil else { return }
        let blurView = NSVisualEffectView(frame: contentView.bounds)
        blurView.autoresizingMask = [.width, .height]
        blurView.blendingMode = .behindWindow
        blurView.material = .underWindowBackground
        blurView.state = .active
        contentView.addSubview(blurView, positioned: .below, relativeTo: tab.webView)
        fallbackBlurView = blurView
        usesFallbackBlur = true
    }
}
