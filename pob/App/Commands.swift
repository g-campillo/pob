import AppKit

enum CommandID: String, CaseIterable {
    case toggleRail, focusAddress, reload, back, forward, snapOpaque
    case toggleInspector, showConsole, showPageSource, openInSafari, signIn, closeWindow
}

struct Command {
    let id: CommandID
    let title: String
    /// Empty when the command has no shortcut.
    let key: String
    let modifiers: NSEvent.ModifierFlags
    /// Reserved shortcuts are taken before the page sees them. All others give the page first chance.
    let isReserved: Bool
    let perform: () -> Void
}

/// One list of every action. It feeds the menu bar now and the switcher in Stage 2.
struct CommandList {
    let all: [Command]

    static func standard(perform: @escaping (CommandID) -> Void) -> CommandList {
        func command(
            _ id: CommandID,
            _ title: String,
            key: String = "",
            modifiers: NSEvent.ModifierFlags = [],
            reserved: Bool = false
        ) -> Command {
            Command(id: id, title: title, key: key, modifiers: modifiers, isReserved: reserved) { perform(id) }
        }

        return CommandList(all: [
            command(.toggleRail, "Show or Hide Rail", key: "b", modifiers: .command),
            command(.focusAddress, "Open Location", key: "l", modifiers: .command, reserved: true),
            command(.reload, "Reload", key: "r", modifiers: .command),
            command(.back, "Back", key: "[", modifiers: .command),
            command(.forward, "Forward", key: "]", modifiers: .command),
            command(.snapOpaque, "Snap to Opaque", key: "o", modifiers: [.option, .command]),
            command(.toggleInspector, "Web Inspector", key: "i", modifiers: [.option, .command]),
            command(.showConsole, "Console", key: "c", modifiers: [.option, .command]),
            command(.showPageSource, "Page Source", key: "u", modifiers: [.option, .command]),
            command(.openInSafari, "Open in Safari"),
            command(.signIn, "Sign In with AutoFill"),
            command(.closeWindow, "Close Window", key: "w", modifiers: .command, reserved: true),
        ])
    }

    func command(_ id: CommandID) -> Command? {
        all.first { $0.id == id }
    }

    func reservedCommand(key: String, modifiers: NSEvent.ModifierFlags) -> Command? {
        all.first { $0.isReserved && $0.key == key && $0.modifiers == modifiers }
    }
}
