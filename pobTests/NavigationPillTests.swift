import AppKit
import Foundation
import Testing
@testable import pob

func pillButton(_ label: String, in pill: NavigationPill) -> NSButton? {
    pill.subviewsDeep.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label }
}

@Suite struct NavigationPillTests {
    @Test func itStartsWithNowhereToGo() throws {
        let pill = NavigationPill()
        let back = try #require(pillButton("Back", in: pill))
        let forward = try #require(pillButton("Forward", in: pill))
        #expect(!back.isEnabled)
        #expect(!forward.isEnabled)
    }

    @Test func itFollowsWhatThePageCanDo() throws {
        let pill = NavigationPill()
        let back = try #require(pillButton("Back", in: pill))
        let forward = try #require(pillButton("Forward", in: pill))
        pill.update(canGoBack: true, canGoForward: false)
        #expect(back.isEnabled)
        #expect(!forward.isEnabled)
        pill.update(canGoBack: false, canGoForward: true)
        #expect(!back.isEnabled)
        #expect(forward.isEnabled)
    }

    @Test func itsButtonsSendBackAndForward() throws {
        let pill = NavigationPill()
        pill.update(canGoBack: true, canGoForward: true)
        var sent: [CommandID] = []
        pill.onNavigate = { sent.append($0) }
        try #require(pillButton("Back", in: pill)).performClick(nil)
        try #require(pillButton("Forward", in: pill)).performClick(nil)
        #expect(sent == [.back, .forward])
    }

    @Test func itsACapsuleOfRegularGlass() throws {
        let glass = try #require(NavigationPill().subviewsDeep.compactMap { $0 as? NSGlassEffectView }.first)
        #expect(glass.style == .regular)
        #expect(glass.cornerRadius == NavigationPill.height / 2)
    }

    @Test func itsCurveRunsAlongsideTheWindowsCorner() {
        #expect(NavigationPill.inset + NavigationPill.height / 2 == Rail.cornerRadius + Rail.inset)
    }

    @Test func itsJustBigEnoughForTwoButtons() {
        #expect(NavigationPill().fittingSize == NSSize(width: 56, height: 28))
    }

    @Test func bothButtonsShowTheyCanBeClicked() {
        let buttons = NavigationPill().subviewsDeep.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        #expect(buttons.allSatisfy { $0 is HoverButton })
        #expect(buttons.map { $0.accessibilityLabel() } == ["Back", "Forward"])
    }
}
