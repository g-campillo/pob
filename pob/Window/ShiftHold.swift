import AppKit

/// Tells the window when Shift is held on its own, which brings up the back and forward pill and the address pill.
/// The hold counts once Shift has been down alone for `delay`, so typing a capital or pressing a shortcut never
/// flashes them.
final class ShiftHold {
    static let delay: Duration = .milliseconds(200)

    /// Called with true once the hold counts, and with false when it ends.
    var onChange: ((Bool) -> Void)?

    /// Replaceable so tests needn't wait out the real time. Zero counts at once.
    var delay = ShiftHold.delay
    private(set) var isHeld = false

    private var isShiftDown = false
    /// Another key or modifer joined this press, so it can't count until Shift comes up.
    private var isSpoiled = false
    private var wait: Task<Void, Never>?
    private var monitor: Any?

    /// Follows the keyboard while `window` is the key window. Every event carries on to the page untouched.
    func watch(_ window: NSWindow) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self, weak window] event in
            guard let self, window?.isKeyWindow == true else { return event }

            if event.type == .flagsChanged {
                modifiersChanged(event.modifierFlags)
            } else {
                keyPressed()
            }

            return event
        }
    }

    /// The window is closing, so the monitor goes with it.
    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }

        monitor = nil
        reset()
    }

    /// From every change to the modifer keys. Caps Lock and Fn are left out, so they never get in the way.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let held = flags.intersection([.shift, .control, .option, .command])
        isShiftDown = held.contains(.shift)

        if !isShiftDown {
            isSpoiled = false
        } else if held != .shift {
            isSpoiled = true
        }

        if held == .shift, !isSpoiled {
            begin()
            return
        }

        end()
    }

    /// A key pressed with Shift down is typing or a shortcut, so this press stops counting.
    func keyPressed() {
        guard isShiftDown else { return }
        isSpoiled = true
        end()
    }

    /// The window stopped being the key window, so Shift coming up would never reach it.
    func reset() {
        isShiftDown = false
        isSpoiled = false
        end()
    }

    private func begin() {
        guard !isHeld, wait == nil else { return }  // already counting, or already waiting
        guard delay > .zero else { return setHeld(true) }

        wait = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            wait = nil
            setHeld(true)
        }
    }

    private func end() {
        wait?.cancel()
        wait = nil
        setHeld(false)
    }

    private func setHeld(_ held: Bool) {
        guard held != isHeld else { return }
        isHeld = held
        onChange?(held)
    }
}
