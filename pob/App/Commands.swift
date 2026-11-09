import AppKit

enum CommandID: String, CaseIterable {
    case toggleRail, focusAddress, reload, back, forward, snapOpaque
    case toggleInspector, showConsole, showPageSource, openInSafari, signIn, bookmarkPage
    case openSwitcher, openSwitcherFromPage, newWindow, newPrivateWindow, reopenTab, closeTab, closeWindow, nextTab, previousTab
    case selectTab1, selectTab2, selectTab3, selectTab4, selectTab5, selectTab6, selectTab7, selectTab8, selectTab9
    case find, print, zoomIn, zoomOut, actualSize
    case screenRecordingSettings, resetSitePermissions, toggleSiteBlocking, makeDefaultBrowser
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

/// One list of every action. It feeds the menu bar and the switcher.
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
            command(.bookmarkPage, "Bookmark This Page", key: "d", modifiers: .command),
            command(.openSwitcher, "New Tab", key: "t", modifiers: .command, reserved: true),
            command(.openSwitcherFromPage, "Open Switcher", key: "k", modifiers: .command),
            command(.newWindow, "New Window", key: "n", modifiers: .command, reserved: true),
            command(.newPrivateWindow, "New Private Window", key: "n", modifiers: [.shift, .command], reserved: true),
            command(.reopenTab, "Reopen Closed Tab", key: "t", modifiers: [.shift, .command], reserved: true),
            command(.closeTab, "Close Tab", key: "w", modifiers: .command, reserved: true),
            command(.closeWindow, "Close Window", key: "w", modifiers: [.shift, .command], reserved: true),
            command(.nextTab, "Next Tab", key: "\t", modifiers: .control, reserved: true),
            command(.previousTab, "Previous Tab", key: "\t", modifiers: [.control, .shift], reserved: true),
            command(.find, "Find", key: "f", modifiers: .command),
            command(.print, "Print…", key: "p", modifiers: .command),
            command(.zoomIn, "Zoom In", key: "=", modifiers: .command),
            command(.zoomOut, "Zoom Out", key: "-", modifiers: .command),
            command(.actualSize, "Actual Size", key: "0", modifiers: .command),
            command(.screenRecordingSettings, "Screen Recording Settings"),
            command(.resetSitePermissions, "Reset Permissions for This Site"),
            command(.toggleSiteBlocking, "Toggle Ad Blocking for This Site"),
            command(.makeDefaultBrowser, "Make pob the Default Browser"),
            command(.selectTab1, "Select Tab 1", key: "1", modifiers: .command, reserved: true),
            command(.selectTab2, "Select Tab 2", key: "2", modifiers: .command, reserved: true),
            command(.selectTab3, "Select Tab 3", key: "3", modifiers: .command, reserved: true),
            command(.selectTab4, "Select Tab 4", key: "4", modifiers: .command, reserved: true),
            command(.selectTab5, "Select Tab 5", key: "5", modifiers: .command, reserved: true),
            command(.selectTab6, "Select Tab 6", key: "6", modifiers: .command, reserved: true),
            command(.selectTab7, "Select Tab 7", key: "7", modifiers: .command, reserved: true),
            command(.selectTab8, "Select Tab 8", key: "8", modifiers: .command, reserved: true),
            command(.selectTab9, "Select Last Tab", key: "9", modifiers: .command, reserved: true),
        ])
    }

    func command(_ id: CommandID) -> Command? {
        all.first { $0.id == id }
    }

    func reservedCommand(key: String, modifiers: NSEvent.ModifierFlags) -> Command? {
        all.first { $0.isReserved && $0.key == key && $0.modifiers == modifiers }
    }

    /// Tab is matched by key code 48, because Shift changes its character.
    func reservedCommand(for event: NSEvent) -> Command? {
        guard let key = event.keyCode == 48 ? "\t" : event.charactersIgnoringModifiers?.lowercased() else { return nil }
        return reservedCommand(key: key, modifiers: event.modifierFlags.intersection([.command, .option, .shift, .control]))
    }

    /// True when the key is taken and goes no further. A repeat of these is taken and dropped: a held ⌘W would run
    /// through the tabs and on into the next window, and a held ⌘N or ⇧⌘N would open a window per repeat.
    func performReserved(_ event: NSEvent) -> Bool {
        guard let command = reservedCommand(for: event) else { return false }
        if !event.isARepeat || ![.closeTab, .closeWindow, .newWindow, .newPrivateWindow].contains(command.id) {
            command.perform()
        }
        return true
    }
}
