import AppKit
import SwiftUI

/// The window that holds an open Workspace or Agent picker, hung from its
/// pill as a child of the quick entry panel.
///
/// A non-activating panel, like the quick entry panel, so typing into the
/// search does not make Toastty the active app. An `NSPopover` would: its
/// window takes typing only once the app is active.
@MainActor
final class QuickEntryPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘1 or ⌘2 while the picker has focus.
    var onPickerShortcut: (QuickEntryPickerKind) -> Void = { _ in }
    /// ⌘↩: choose, then create the task.
    var onSubmitTask: () -> Void = {}
    /// ⌘→. Returns false when the picker has no use for it, so the search
    /// field moves its caret.
    var onCommandRight: () -> Bool = { false }
    var onClose: () -> Void = {}
    /// The picker lost focus: a click elsewhere, or another app came forward.
    var onResignKey: () -> Void = {}
    /// The picker's search, so a shortcut that clears it also clears the
    /// field at once.
    var currentQuery: () -> String = { "" }
    /// A digit with no modifier. Returns true when it picked a Frequent
    /// preset; otherwise the digit is typed into the search.
    var onNumberKey: (Int) -> Bool = { _ in false }

    /// The pill and the screen area the picker was placed for; a size
    /// change places it again.
    private var anchor: (pill: NSRect, visibleFrame: NSRect)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        setAccessibilityIdentifier("quick-entry.picker")
    }

    /// Command shortcuts stay inside the picker, as they do in the quick
    /// entry panel, so Toastty's menus never act on the window behind.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if modifiers == .command, event.keyCode == QuickEntryPanel.rightArrowKeyCode, onCommandRight() {
            // As in the search field's own key handling: the next key can
            // arrive before SwiftUI shows the cleared search.
            if let editor = firstResponder as? NSTextView, editor.string != currentQuery() {
                editor.string = currentQuery()
            }
            return true
        }
        switch QuickEntryPanel.commandAction(key: key, keyCode: event.keyCode, modifiers: modifiers) {
        case .edit(let selector):
            _ = firstResponder?.tryToPerform(selector, with: nil)
        case .textNavigation:
            firstResponder?.keyDown(with: event)
        case .picker(let kind):
            onPickerShortcut(kind)
        case .submit:
            onSubmitTask()
        case .close:
            onClose()
        case .application:
            return super.performKeyEquivalent(with: event)
        case .ignore:
            break
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        onClose()
    }

    /// Takes 1–9 before the search field sees them, while the picker has a
    /// use for the digit.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let characters = event.characters, characters.count == 1,
           let number = Int(characters), number > 0,
           // While an input method is composing, its keys are its own.
           (firstResponder as? NSTextView)?.hasMarkedText() != true,
           onNumberKey(number) {
            return
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey()
    }

    /// Places the picker for its pill, given in screen coordinates.
    func place(size: NSSize, pill: NSRect, visibleFrame: NSRect) {
        anchor = (pill, visibleFrame)
        setFrame(QuickEntryPickerPlacement.frame(size: size, pill: pill, visibleFrame: visibleFrame).frame, display: false)
    }

    /// Fits the content's size, placed again for its pill so a longer list
    /// cannot run off the screen.
    func fit(_ size: NSSize) {
        let size = NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard size.width > 0, size.height > 0, size != frame.size, let anchor else { return }
        let placement = QuickEntryPickerPlacement.frame(size: size, pill: anchor.pill, visibleFrame: anchor.visibleFrame)
        setFrame(placement.frame, display: true)
        invalidateShadow()
    }
}

/// Where a picker opens.
enum QuickEntryPickerPlacement {
    /// The gap between the pill and the picker; the picker then overlaps
    /// the panel's bottom edge a little, as in the design.
    static let gap: CGFloat = 6

    /// Below the pill, left edges aligned, or above it when the screen has
    /// no room below. Kept inside the screen's visible area.
    static func frame(size: NSSize, pill: NSRect, visibleFrame visible: NSRect) -> (frame: NSRect, opensUpward: Bool) {
        let x = min(max(pill.minX, visible.minX), max(visible.minX, visible.maxX - size.width))
        let below = pill.minY - gap - size.height
        if below >= visible.minY {
            return (NSRect(x: x, y: below, width: size.width, height: size.height), false)
        }
        let above = pill.maxY + gap
        if above + size.height <= visible.maxY {
            return (NSRect(x: x, y: above, width: size.width, height: size.height), true)
        }
        return (NSRect(x: x, y: visible.minY, width: size.width, height: size.height), false)
    }

    /// A pill's frame on screen, from its frame in the panel's top-left
    /// coordinates.
    static func screenFrame(of pill: CGRect, inPanelFrame panel: NSRect) -> NSRect {
        NSRect(x: panel.minX + pill.minX, y: panel.maxY - pill.maxY, width: pill.width, height: pill.height)
    }
}

/// The picker's search field. Arrow keys, Tab, Return and Esc go to the
/// picker; everything else edits the search.
struct QuickEntryPickerSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    /// ← →; returns false to move the caret instead.
    let onArrow: (Int) -> Bool
    let onTab: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(field: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.textColor = NSColor(ToastyTheme.primaryText)
        textField.maximumNumberOfLines = 1
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.isScrollable = true
        textField.setAccessibilityIdentifier("quick-entry.picker.search")
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The picker's window is new each time it opens; the field takes
        // focus once it is in it.
        DispatchQueue.main.async { [weak textField] in
            guard let textField, let window = textField.window else { return }
            window.makeFirstResponder(textField)
        }
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.field = self
        textField.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(QuickEntryView.mutedText),
            .font: NSFont.systemFont(ofSize: 13),
        ])
        // The picker clears the search when it moves between columns.
        guard textField.stringValue != text else { return }
        if let editor = textField.currentEditor() as? NSTextView {
            editor.string = text
        }
        textField.stringValue = text
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: QuickEntryPickerSearchField

        init(field: QuickEntryPickerSearchField) {
            self.field = field
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            field.text = textField.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // While an input method is composing, its keys are its own.
            guard textView.hasMarkedText() == false else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                field.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                field.onMove(1)
            case #selector(NSResponder.moveLeft(_:)):
                return field.onArrow(-1)
            case #selector(NSResponder.moveRight(_:)):
                return field.onArrow(1)
            case #selector(NSResponder.insertTab(_:)):
                field.onTab(1)
            case #selector(NSResponder.insertBacktab(_:)):
                field.onTab(-1)
            case #selector(NSResponder.insertNewline(_:)):
                field.onSubmit()
            // A key binding can turn Esc into word completion.
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                field.onCancel()
            default:
                return false
            }
            // Tab, or a row that opens the columns, clears the search. The
            // field must show that before the next key, which can arrive
            // before SwiftUI updates the view.
            if textView.string != field.text {
                textView.string = field.text
            }
            return true
        }
    }
}
