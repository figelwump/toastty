import AppKit
import CoreState
import Foundation

/// A short record, in the log, of the key presses that follow Show Terminal.
///
/// A report that the coordinator's terminal did not react to keys has three
/// possible places for the fault: the key went to another view, the
/// terminal's view dropped or changed it, or the agent did not act on it.
/// The record says, for each key press in the terminal's window, which view
/// had the keyboard and what the terminal's view sent on. A window that got
/// no key press at all has no line: another app took the keys.
///
/// It names a key by its kind and its modifier flags only, and never by a
/// typed character. It keeps `budget` key presses after each start, so a
/// person who works in the terminal for a long time fills no log.
@MainActor
final class CoordinatorTerminalKeyLog {
    static let budget = 40

    /// Whether the view is the one that takes the keyboard for the
    /// coordinator's terminal.
    var isCoordinatorTerminal: (NSResponder) -> Bool = { _ in false }
    /// The window that shows the coordinator's terminal. Key presses in
    /// another window are no part of the record.
    var terminalWindow: () -> NSWindow? = { nil }
    /// Facts of the coordinator that each line carries, such as why its
    /// waiting message waits.
    var context: () -> [String: String] = { [:] }

    nonisolated(unsafe) private var monitor: Any?
    private var remainingKeyPresses = 0
    /// The key press that the monitor recorded last has not reached the
    /// terminal's view yet. The view's line belongs to the same press.
    private var awaitsTerminalReport = false

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Starts the record, or gives a running record its whole budget again.
    func start() {
        remainingKeyPresses = Self.budget
        guard monitor == nil else { return }
        // The monitor sees a key press before any view does, so it also
        // records the presses that never reach the terminal.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return event
        }
    }

    func stop() {
        awaitsTerminalReport = false
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func record(_ event: NSEvent) {
        awaitsTerminalReport = false
        guard remainingKeyPresses > 0, let window = event.window, window === terminalWindow() else { return }
        remainingKeyPresses -= 1
        awaitsTerminalReport = true
        var metadata = context()
        metadata["key"] = Self.keyName(keyCode: event.keyCode)
        metadata["modifiers"] = Self.modifierNames(event.modifierFlags)
        metadata["repeat"] = event.isARepeat ? "true" : "false"
        metadata["keyboard_owner"] = keyboardOwner(in: window)
        metadata["app_active"] = NSApp.isActive ? "true" : "false"
        metadata["left_in_record"] = String(remainingKeyPresses)
        ToasttyLog.info("Key press while the coordinator's panel shows its terminal", category: .input, metadata: metadata)
    }

    /// What the coordinator's terminal did with the key press that the
    /// monitor just recorded.
    func record(_ press: TerminalKeyPress) {
        guard awaitsTerminalReport else { return }
        awaitsTerminalReport = false
        ToasttyLog.info("The coordinator's terminal took a key press", category: .input, metadata: [
            "key": Self.keyName(keyCode: press.keyCode),
            "modifiers": Self.modifierNames(press.modifierFlags),
            "counts_as": press.localInputKind.rawValue,
            "composed_text_before": press.hadComposedText ? "true" : "false",
            "sent_to_ghostty": press.ghosttyModifiers == nil ? "false" : "true",
            "ghostty_modifiers": press.ghosttyModifiers.map { String($0, radix: 16) } ?? "none",
            "sent_as_composing": press.composing ? "true" : "false",
            "sent_text": press.sentText ? "true" : "false",
            "ghostty_handled": press.ghosttyHandled.map { $0 ? "true" : "false" } ?? "none",
        ])
    }

    /// The view that has the keyboard in the terminal's window.
    func keyboardOwner() -> String {
        guard let window = terminalWindow() else { return "terminal_has_no_window" }
        guard window.isKeyWindow else { return "another_window" }
        return keyboardOwner(in: window)
    }

    private func keyboardOwner(in window: NSWindow) -> String {
        guard let responder = window.firstResponder else { return "none" }
        if isCoordinatorTerminal(responder) { return "coordinator_terminal" }
        if responder is CoordinatorComposerTextView { return "coordinator_chat_field" }
        if responder is TerminalHostView { return "another_terminal" }
        if responder === window { return "window" }
        return String(describing: type(of: responder))
    }

    /// The key's kind. A key that types a character is `character`, so the
    /// log never holds what a person typed.
    static func keyName(keyCode: UInt16) -> String {
        switch keyCode {
        case 123: "left"
        case 124: "right"
        case 125: "down"
        case 126: "up"
        case 36: "return"
        case 76: "enter"
        case 53: "escape"
        case 48: "tab"
        case 51: "delete"
        case 117: "forward_delete"
        case 116: "page_up"
        case 121: "page_down"
        case 115: "home"
        case 119: "end"
        default: "character"
        }
    }

    static func modifierNames(_ flags: NSEvent.ModifierFlags) -> String {
        let names: [(NSEvent.ModifierFlags, String)] = [
            (.command, "command"), (.option, "option"), (.control, "control"), (.shift, "shift"),
            (.capsLock, "capsLock"), (.numericPad, "numericPad"), (.function, "function"),
        ]
        let present = names.filter { flags.contains($0.0) }.map(\.1)
        return present.isEmpty ? "none" : present.joined(separator: ",")
    }
}
