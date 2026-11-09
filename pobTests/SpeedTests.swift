import AppKit
import Foundation
import Testing
@testable import pob

/// The spec's targets: ⌘T to typing and a tab switch, each under 50 ms. Timing on a busy machine would make the normal
/// suite flaky, so these run only when asked, with `TEST_RUNNER_POB_SPEED=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["POB_SPEED"] == "1"))
struct SpeedTests {
    static let warmUps = 3
    static let runs = 30
    static let target: Duration = .milliseconds(50)

    /// Times `run` after the warm-ups, with `after` untimed between runs, and prints the median and the slowest.
    func measure(_ name: String, _ run: () -> Void, after: () async -> Void) async -> Duration {
        var times: [Duration] = []
        for index in 0..<(Self.warmUps + Self.runs) {
            let elapsed = ContinuousClock().measure(run)
            if index >= Self.warmUps { times.append(elapsed) }
            await after()
            try? await Task.sleep(for: .milliseconds(20)) // lets the run loop turn, as it would between keys
        }
        times.sort()
        let median = (times[Self.runs / 2 - 1] + times[Self.runs / 2]) / 2
        print(String(format: "Speed: %@: median %.2f ms, slowest %.2f ms", name, median / .milliseconds(1), times.last! / .milliseconds(1)))
        return median
    }

    /// A window over loaded pages on a loopback server, so a saved one restores the way a real page does.
    func window(pages count: Int, server: LocalServer) async -> (controller: WindowController, tabs: TabManager) {
        let paragraphs = String(repeating: "<p>Some text for the page to lay out, with a <a href=\"#\">link</a> in it.</p>", count: 200)
        for index in 0..<count {
            server.routes["/\(index)"] = .body(Data("<title>Page \(index)</title>\(paragraphs)".utf8), headers: ["Content-Type": "text/html"])
        }
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.updateFavicon = { _, _, _ in } // no icons, so every rail update looks for them on disk
        let controller = WindowController(appearance: testAppearance(), tabs: tabs)
        for index in 0..<count {
            let tab = tabs.newTab(nil, activate: true)
            await finishLoading(tab) { tab.load(.url(server.url("/\(index)"))) }
        }
        return (controller, tabs)
    }

    @Test func openingTheSwitcherIsQuick() async throws {
        let server = LocalServer()
        try await server.start()
        defer { server.stop() }
        let (controller, _) = await window(pages: 5, server: server)
        let field = controller.switcher.field
        let median = await measure("Opening the switcher") {
            controller.perform(.openSwitcher)
            controller.window?.layoutIfNeeded()
        } after: {
            #expect(field.currentEditor() != nil && field.window?.firstResponder === field.currentEditor())
            controller.switcher.onCancel?()
        }
        #expect(median < Self.target)
    }

    @Test func switchingBetweenLiveTabsIsQuick() async throws {
        let server = LocalServer()
        try await server.start()
        defer { server.stop() }
        let (controller, tabs) = await window(pages: 2, server: server)
        let ids = tabs.list.records.map(\.id)
        var next = 0
        let median = await measure("Switching between live tabs") {
            tabs.activate(ids[next])
        } after: {
            #expect(tabs.list.activeID == ids[next] && tabs.phase(of: ids[1 - next]) == .background)
            #expect(tabs.activeTab?.pageView.window === controller.window) // the window, not just the list, switched
            next = 1 - next
        }
        #expect(median < Self.target)
    }

    @Test func returningToASavedTabIsQuick() async throws {
        let server = LocalServer()
        try await server.start()
        defer { server.stop() }
        let (controller, tabs) = await window(pages: 2, server: server)
        let (first, saved) = (tabs.list.records[0].id, tabs.list.records[1].id)
        func stepDown() {
            tabs.activate(first)
            tabs.updatePhases(now: .now + 700, memoryPressure: false)
            tabs.updatePhases(now: .now + 800, memoryPressure: true)
            #expect(tabs.phase(of: saved) == .saved)
        }
        stepDown()
        let median = await measure("Returning to a saved tab") {
            tabs.activate(saved)
        } after: {
            #expect(tabs.list.activeID == saved && tabs.activeTab?.pageView.window === controller.window)
            #expect(await eventually { tabs.activeTab?.webView.isLoading == false }) // each run starts from a settled page
            stepDown()
        }
        #expect(median < Self.target)
    }
}
