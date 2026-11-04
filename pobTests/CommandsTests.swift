import AppKit
import Testing
@testable import pob

@Suite struct CommandsTests {
    let list = CommandList.standard { _ in }

    @Test func shortcutsMatchSpec() {
        let expected: [(CommandID, String, NSEvent.ModifierFlags)] = [
            (.toggleRail, "b", .command),
            (.focusAddress, "l", .command),
            (.reload, "r", .command),
            (.back, "[", .command),
            (.forward, "]", .command),
            (.closeTab, "w", .command),
            (.closeWindow, "w", [.shift, .command]),
            (.openSwitcherFromPage, "k", .command),
            (.snapOpaque, "o", [.option, .command]),
            (.toggleInspector, "i", [.option, .command]),
            (.showConsole, "c", [.option, .command]),
            (.showPageSource, "u", [.option, .command]),
        ]
        for (id, key, modifiers) in expected {
            #expect(list.command(id)?.key == key, "\(id)")
            #expect(list.command(id)?.modifiers == modifiers, "\(id)")
        }
    }
    @Test func shortcutsAreUnique() {
        let bound = list.all.filter { !$0.key.isEmpty }.map { "\($0.key)-\($0.modifiers.rawValue)" }
        #expect(Set(bound).count == bound.count)
    }
    @Test func onlyAlwaysReachShortcutsAreReserved() {
        #expect(Set(list.all.filter(\.isReserved).map(\.id)) == [
            .focusAddress, .openSwitcher, .newWindow, .reopenTab, .closeTab, .closeWindow, .nextTab, .previousTab,
            .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5, .selectTab6, .selectTab7, .selectTab8, .selectTab9,
        ])
    }
    @Test func reservedLookupIgnoresPageFirstShortcuts() {
        #expect(list.reservedCommand(key: "l", modifiers: .command)?.id == .focusAddress)
        #expect(list.reservedCommand(key: "b", modifiers: .command) == nil)
    }
    /// Shift turns Tab's character into backtab, so Tab has to be matched by its key code.
    @Test func tabIsMatchedByKeyCodeWhateverShiftDoesToIt() {
        #expect(list.reservedCommand(for: keyDown("\t", keyCode: 48, [.control]))?.id == .nextTab)
        #expect(list.reservedCommand(for: keyDown("\u{19}", keyCode: 48, [.control, .shift]))?.id == .previousTab)
        #expect(list.reservedCommand(for: keyDown("\t", keyCode: 48, [])) == nil)
    }
    @Test func shiftedLettersMatchTheirLowercaseShortcut() {
        #expect(list.reservedCommand(for: keyDown("T", keyCode: 17, [.shift, .command]))?.id == .reopenTab)
        #expect(list.reservedCommand(for: keyDown("t", keyCode: 17, .command))?.id == .openSwitcher)
        #expect(list.reservedCommand(for: keyDown("t", keyCode: 17, [])) == nil)
    }
    @Test func everyCommandReachesTheHandler() {
        var received: [CommandID] = []
        let recording = CommandList.standard { received.append($0) }
        recording.all.forEach { $0.perform() }
        #expect(Set(received) == Set(CommandID.allCases))
    }
    @Test func fileMenuHoldsTabAndWindowCommands() {
        let file = MainMenu.build(commands: list).item(withTitle: "File")?.submenu
        #expect(file?.items.map(\.title) == ["New Tab", "New Window", "Reopen Closed Tab", "Close Tab", "Close Window"])
    }
    /// A shortcut that isn't reserved can only fire from the menu bar, once the page has passed on it.
    @Test func everyPageFirstShortcutIsInTheMenu() {
        let items = MainMenu.build(commands: list).items.compactMap(\.submenu).flatMap(\.items)
        for command in list.all where !command.key.isEmpty && !command.isReserved {
            #expect(items.contains { $0.keyEquivalent == command.key && $0.keyEquivalentModifierMask == command.modifiers }, "\(command.id)")
        }
    }
    @Test func menuKeepsStandardEditing() {
        let menu = MainMenu.build(commands: list)
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        for (action, key) in [("cut:", "x"), ("copy:", "c"), ("paste:", "v"), ("selectAll:", "a"), ("undo:", "z")] {
            #expect(items.contains { $0.action == Selector(action) && $0.keyEquivalent == key }, "missing \(action)")
        }
    }

    /// A held key repeats until it's let go, so ⌘W would run through the tabs and on into the next window, and ⌘N would
    /// open a window per repeat. Each repeat has to be taken and not passed on, or the menu's key equivalent fires instead.
    @Test func aHeldCloseOrNewWindowActsOnceAndTakesEveryRepeat() {
        var received: [CommandID] = []
        let recording = CommandList.standard { received.append($0) }
        let held: [(String, UInt16, NSEvent.ModifierFlags, CommandID)] = [
            ("w", 13, .command, .closeTab),
            ("W", 13, [.shift, .command], .closeWindow),
            ("n", 45, .command, .newWindow),
        ]
        for (key, keyCode, modifiers, id) in held {
            received = []
            #expect(recording.performReserved(keyDown(key, keyCode: keyCode, modifiers)))
            for _ in 0..<3 {
                #expect(recording.performReserved(keyDown(key, keyCode: keyCode, modifiers, isARepeat: true)))
            }
            #expect(received == [id], "\(id)")
        }
    }
    @Test func otherReservedKeysKeepRepeating() {
        var received: [CommandID] = []
        let recording = CommandList.standard { received.append($0) }
        #expect(recording.performReserved(keyDown("\t", keyCode: 48, .control, isARepeat: true)))
        #expect(received == [.nextTab])
    }
    @Test func aKeyThatIsntReservedIsLeftAlone() {
        var received: [CommandID] = []
        let recording = CommandList.standard { received.append($0) }
        #expect(!recording.performReserved(keyDown("b", keyCode: 11, .command)))
        #expect(!recording.performReserved(keyDown("b", keyCode: 11, .command, isARepeat: true)))
        #expect(received.isEmpty)
    }

    private func keyDown(_ characters: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isARepeat,
            keyCode: keyCode
        )!
    }
}
