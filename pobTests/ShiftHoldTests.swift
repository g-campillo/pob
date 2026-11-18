import AppKit
import Foundation
import Testing
@testable import pob

/// Holds Shift on its own in the window, and the hold counts at once.
func holdShift(in controller: WindowController) {
    controller.shiftHold.delay = .zero
    controller.shiftHold.modifiersChanged(.shift)
}

@Suite struct ShiftHoldTests {
    func hold(after delay: Duration = .milliseconds(20)) -> ShiftHold {
        let hold = ShiftHold()
        hold.delay = delay
        return hold
    }

    @Test func shiftOnItsOwnCountsAfterTheDelay() async {
        let hold = hold()
        var changes: [Bool] = []
        hold.onChange = { changes.append($0) }
        hold.modifiersChanged(.shift)
        #expect(!hold.isHeld) // not yet, so a quick capital never flashes the pills
        #expect(await eventually { hold.isHeld })
        hold.modifiersChanged([])
        #expect(!hold.isHeld)
        #expect(changes == [true, false])
    }

    @Test func lettingGoBeforeTheDelayNeverCounts() async throws {
        let hold = hold()
        var changes: [Bool] = []
        hold.onChange = { changes.append($0) }
        hold.modifiersChanged(.shift)
        hold.modifiersChanged([])
        try await Task.sleep(for: .milliseconds(100))
        #expect(!hold.isHeld)
        #expect(changes.isEmpty)
    }

    @Test func typingWithShiftDownStopsThePressCounting() async throws {
        let hold = hold()
        hold.modifiersChanged(.shift)
        #expect(await eventually { hold.isHeld })
        hold.keyPressed()
        #expect(!hold.isHeld)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!hold.isHeld) // not until Shift comes up and goes down again
        hold.modifiersChanged([])
        hold.modifiersChanged(.shift)
        #expect(await eventually { hold.isHeld })
    }

    @Test func aCapitalTypedQuicklyNeverCounts() async throws {
        let hold = hold()
        hold.modifiersChanged(.shift)
        hold.keyPressed()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!hold.isHeld)
    }

    @Test func aShortcutWithShiftNeverCountsEvenAfterItsOtherKeyComesUp() async throws {
        let hold = hold()
        hold.modifiersChanged([.shift, .command])
        hold.modifiersChanged(.shift) // ⌘ comes up first
        try await Task.sleep(for: .milliseconds(100))
        #expect(!hold.isHeld)
    }

    @Test func anotherModifierEndsAHold() async {
        let hold = hold()
        hold.modifiersChanged(.shift)
        #expect(await eventually { hold.isHeld })
        hold.modifiersChanged([.shift, .option])
        #expect(!hold.isHeld)
    }

    @Test func capsLockDoesNotGetInTheWay() async {
        let hold = hold()
        hold.modifiersChanged([.shift, .capsLock])
        #expect(await eventually { hold.isHeld })
    }

    @Test func aKeyWithoutShiftChangesNothing() async {
        let hold = hold()
        hold.keyPressed()
        hold.modifiersChanged(.shift)
        #expect(await eventually { hold.isHeld })
    }

    @Test func resettingEndsTheHoldAndAWait() async throws {
        let hold = hold()
        hold.modifiersChanged(.shift)
        #expect(await eventually { hold.isHeld })
        hold.reset()
        #expect(!hold.isHeld)

        hold.modifiersChanged(.shift)
        hold.reset()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!hold.isHeld)
    }

    @Test func aZeroDelayCountsAtOnce() {
        let hold = hold(after: .zero)
        hold.modifiersChanged(.shift)
        #expect(hold.isHeld)
    }
}

@Suite struct ShiftHoldWiringTests {
    /// A window over one tab whose page has loaded, with the pills waiting for Shift.
    func controller() async -> WindowController {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        let controller = WindowController(appearance: testAppearance(), tabs: tabs)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        return controller
    }

    @Test func bothPillsWaitForShift() async {
        let controller = await controller()
        #expect(controller.navigationPill.isHidden)
        #expect(controller.pill.isHidden)
    }

    @Test func holdingShiftBringsUpBothPillsAndLettingGoHidesThem() async {
        let controller = await controller()
        holdShift(in: controller)
        #expect(!controller.navigationPill.isHidden)
        #expect(!controller.pill.isHidden)
        #expect(controller.pill.currentURL?.host() == "localhost")
        controller.shiftHold.modifiersChanged([])
        #expect(controller.navigationPill.isHidden)
        #expect(controller.pill.isHidden)
    }

    @Test func theWindowLosingTheKeyboardLetsGoOfShift() async {
        let controller = await controller()
        holdShift(in: controller)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(!controller.shiftHold.isHeld)
        #expect(controller.navigationPill.isHidden)
        #expect(controller.pill.isHidden)
    }

    @Test func theOpenRailKeepsBothPillsAwayEvenWithShift() async {
        let controller = await controller()
        controller.revealRailImmediately()
        holdShift(in: controller)
        #expect(controller.navigationPill.isHidden)
        #expect(controller.pill.isHidden)
    }
}
