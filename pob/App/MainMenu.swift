import AppKit

enum MainMenu {
    static func build(commands: CommandList) -> NSMenu {
        let menu = NSMenu()
        addSubmenu("pob", to: menu, items: [
            NSMenuItem(title: "Quit pob", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        addSubmenu("File", to: menu, items: items(
            for: [.openSwitcher, .newWindow, .reopenTab, .closeTab, .closeWindow],
            in: commands
        ))
        addSubmenu("Edit", to: menu, items: editItems())
        addSubmenu("View", to: menu, items: items(for: [.toggleRail, .snapOpaque], in: commands))
        addSubmenu("Go", to: menu, items: items(
            for: [.back, .forward, .reload, .focusAddress, .openSwitcherFromPage],
            in: commands
        ))
        addSubmenu("Develop", to: menu, items: items(
            for: [.toggleInspector, .showConsole, .showPageSource, .openInSafari, .signIn],
            in: commands
        ))
        addSubmenu("Window", to: menu, items: [
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
        ])
        return menu
    }

    /// Hand-built menus don't get these for free, and text fields and pages rely on them.
    private static func editItems() -> [NSMenuItem] {
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.shift, .command]
        return [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            redo,
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ]
    }

    private static func addSubmenu(_ title: String, to menu: NSMenu, items: [NSMenuItem]) {
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private static func items(for ids: [CommandID], in commands: CommandList) -> [NSMenuItem] {
        ids.compactMap(commands.command).map(menuItem)
    }

    private static func menuItem(for command: Command) -> NSMenuItem {
        let target = CommandTarget(command)
        let item = NSMenuItem(title: command.title, action: #selector(CommandTarget.run), keyEquivalent: command.key)
        item.keyEquivalentModifierMask = command.modifiers
        item.target = target
        item.representedObject = target // menu items hold their target weakly
        return item
    }
}

private final class CommandTarget: NSObject {
    private let command: Command

    init(_ command: Command) {
        self.command = command
    }

    @objc func run() {
        command.perform()
    }
}
