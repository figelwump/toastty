import AppKit

enum AlertButtonBehavior {
    case defaultAction
    case cancelAction
}

extension NSAlert {
    @discardableResult
    func addConfiguredButton(
        withTitle title: String,
        behavior: AlertButtonBehavior,
        isDestructive: Bool = false
    ) -> NSButton {
        let button = addButton(withTitle: title)
        // Keep Toastty's existing visual button order while explicitly assigning
        // the standard alert shortcuts: Return activates the CTA and Escape
        // dismisses the alert.
        button.keyEquivalentModifierMask = []
        switch behavior {
        case .defaultAction:
            button.keyEquivalent = "\r"
        case .cancelAction:
            button.keyEquivalent = "\u{1B}"
        }
        button.hasDestructiveAction = isDestructive
        return button
    }
}
