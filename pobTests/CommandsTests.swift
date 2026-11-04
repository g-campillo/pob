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
            (.closeWindow, "w", .command),
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
        #expect(Set(list.all.filter(\.isReserved).map(\.id)) == [.focusAddress, .closeWindow])
    }
    @Test func reservedLookupIgnoresPageFirstShortcuts() {
        #expect(list.reservedCommand(key: "l", modifiers: .command)?.id == .focusAddress)
        #expect(list.reservedCommand(key: "b", modifiers: .command) == nil)
    }
    @Test func everyCommandReachesTheHandler() {
        var received: [CommandID] = []
        let recording = CommandList.standard { received.append($0) }
        recording.all.forEach { $0.perform() }
        #expect(Set(received) == Set(CommandID.allCases))
    }
    @Test func menuKeepsStandardEditing() {
        let menu = MainMenu.build(commands: list)
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        for (action, key) in [("cut:", "x"), ("copy:", "c"), ("paste:", "v"), ("selectAll:", "a"), ("undo:", "z")] {
            #expect(items.contains { $0.action == Selector(action) && $0.keyEquivalent == key }, "missing \(action)")
        }
    }
}
