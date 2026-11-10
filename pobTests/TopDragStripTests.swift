import AppKit
import Testing
@testable import pob

final class ClickSpy: NSView {
    var events: [NSEvent.EventType] = []
    override func mouseDown(with event: NSEvent) { events.append(event.type) }
    override func mouseUp(with event: NSEvent) { events.append(event.type) }
}

@Suite struct TopDragStripTests {
    /// A strip over a spy, the way the window puts it over the page.
    func stripOverSpy() -> (strip: TopDragStrip, spy: ClickSpy, window: NSWindow, dragged: () -> Bool) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let spy = ClickSpy(frame: content.bounds)
        let strip = TopDragStrip(frame: NSRect(x: 0, y: 300 - TopDragStrip.height, width: 400, height: TopDragStrip.height))
        content.addSubview(spy)
        content.addSubview(strip)
        var dragged = false
        strip.startDrag = { _ in dragged = true }
        return (strip, spy, window, { dragged })
    }

    func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func theStripIsAsTallAsATitleBar() {
        #expect(TopDragStrip.height == 32)
    }

    @Test func aPressThatMovesDragsTheWindowAndThePageHearsNothing() {
        let (strip, spy, window, dragged) = stripOverSpy()
        window.postEvent(mouse(.leftMouseDragged, at: NSPoint(x: 120, y: 280), in: window), atStart: false)
        strip.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 100, y: 290), in: window))
        #expect(dragged())
        #expect(spy.events.isEmpty)
    }

    @Test func aPressThatDoesntMoveIsThePagesClick() {
        let (strip, spy, window, dragged) = stripOverSpy()
        window.postEvent(mouse(.leftMouseUp, at: NSPoint(x: 100, y: 290), in: window), atStart: false)
        strip.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 100, y: 290), in: window))
        #expect(!dragged())
        #expect(spy.events == [.leftMouseDown, .leftMouseUp])
        #expect(!strip.isHidden)
    }

    @Test func aShakyClickIsStillAClick() {
        let (strip, spy, window, dragged) = stripOverSpy()
        window.postEvent(mouse(.leftMouseDragged, at: NSPoint(x: 101, y: 291), in: window), atStart: false)
        window.postEvent(mouse(.leftMouseUp, at: NSPoint(x: 101, y: 291), in: window), atStart: false)
        strip.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 100, y: 290), in: window))
        #expect(!dragged())
        #expect(spy.events == [.leftMouseDown, .leftMouseUp])
    }

    @Test func onlyAPressIsTheStripsSoScrollingAndRightClicksReachThePage() {
        #expect(TopDragStrip.takes(.leftMouseDown))
        for type in [NSEvent.EventType.scrollWheel, .rightMouseDown, .mouseMoved, .otherMouseDown] {
            #expect(!TopDragStrip.takes(type))
        }
        #expect(!TopDragStrip.takes(nil))
    }

    @Test func aClickAtTheTopOfARealPageReachesIt() async throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        let controller = WindowController(appearance: testAppearance(), tabs: tabs)
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        await finishLoading(tab) {
            tab.webView.loadHTMLString(
                "<body style='margin:0'><button onclick=\"document.title='clicked'\" style='display:block;width:100%;height:80px'>x</button>",
                baseURL: URL(string: "https://localhost/")
            )
        }
        let strip = try #require(content.subviews.compactMap { $0 as? TopDragStrip }.first)
        #expect(strip.frame.height == 32)
        let point = NSPoint(x: 200, y: content.bounds.height - 10)
        window.postEvent(mouse(.leftMouseUp, at: point, in: window), atStart: false)
        strip.mouseDown(with: mouse(.leftMouseDown, at: point, in: window))
        #expect(await eventually { tab.title == "clicked" })
    }
}
