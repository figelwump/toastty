import SwiftUI

struct ToasttyKeyboardShortcut: Equatable {
    let key: KeyEquivalent
    let modifiers: EventModifiers

    init(
        _ key: KeyEquivalent,
        modifiers: EventModifiers
    ) {
        self.key = key
        self.modifiers = modifiers
    }

    var symbolLabel: String {
        "\(modifiers.symbolLabel)\(String(key.character).uppercased())"
    }

    func helpText(_ title: String) -> String {
        "\(title) (\(symbolLabel))"
    }

    // AppKit uses a tab-delimited trailing column for menu shortcut text.
    // This shows the hint in contextual menus without rebinding the shortcut.
    func menuTitle(_ title: String) -> String {
        "\(title)\t\(symbolLabel)"
    }
}

private extension EventModifiers {
    var symbolLabel: String {
        var label = ""
        if contains(.control) {
            label += "⌃"
        }
        if contains(.option) {
            label += "⌥"
        }
        if contains(.shift) {
            label += "⇧"
        }
        if contains(.command) {
            label += "⌘"
        }
        return label
    }
}

enum ToasttyKeyboardShortcuts {
    static let newTab = ToasttyKeyboardShortcut(
        "t",
        modifiers: [.command]
    )

    static let newWindow = ToasttyKeyboardShortcut(
        "n",
        modifiers: [.command]
    )

    static let toggleSidebar = ToasttyKeyboardShortcut(
        "b",
        modifiers: [.command]
    )

    static let newWorkspace = ToasttyKeyboardShortcut(
        "n",
        modifiers: [.command, .shift]
    )

    static let renameWorkspace = ToasttyKeyboardShortcut(
        "e",
        modifiers: [.command, .shift]
    )

    static let renameTab = ToasttyKeyboardShortcut(
        "e",
        modifiers: [.option, .shift]
    )

    static let closeWorkspace = ToasttyKeyboardShortcut(
        "w",
        modifiers: [.command, .shift]
    )

    static let closePanel = ToasttyKeyboardShortcut(
        "w",
        modifiers: [.command]
    )

    static let toggleFocusedPanel = ToasttyKeyboardShortcut(
        "f",
        modifiers: [.command, .shift]
    )

    static let find = ToasttyKeyboardShortcut(
        "f",
        modifiers: [.command]
    )

    static let findNext = ToasttyKeyboardShortcut(
        "g",
        modifiers: [.command]
    )

    static let findPrevious = ToasttyKeyboardShortcut(
        "g",
        modifiers: [.command, .shift]
    )

    static let browserOpenLocation = ToasttyKeyboardShortcut(
        "l",
        modifiers: [.command]
    )

    static let newBrowser = ToasttyKeyboardShortcut(
        "b",
        modifiers: [.command, .control]
    )

    static let newBrowserTab = ToasttyKeyboardShortcut(
        "b",
        modifiers: [.command, .control, .shift]
    )

    static let browserReload = ToasttyKeyboardShortcut(
        "r",
        modifiers: [.command]
    )

    static let focusNextUnreadOrActivePanel = ToasttyKeyboardShortcut(
        "a",
        modifiers: [.command, .shift]
    )

    static let splitHorizontal = ToasttyKeyboardShortcut(
        "d",
        modifiers: [.command]
    )

    static let splitVertical = ToasttyKeyboardShortcut(
        "d",
        modifiers: [.command, .shift]
    )

    static let focusPreviousPane = ToasttyKeyboardShortcut(
        "[",
        modifiers: [.command]
    )

    static let focusNextPane = ToasttyKeyboardShortcut(
        "]",
        modifiers: [.command]
    )

    static let resizeSplitLeft = ToasttyKeyboardShortcut(
        .leftArrow,
        modifiers: [.command, .control]
    )

    static let resizeSplitRight = ToasttyKeyboardShortcut(
        .rightArrow,
        modifiers: [.command, .control]
    )

    static let resizeSplitUp = ToasttyKeyboardShortcut(
        .upArrow,
        modifiers: [.command, .control]
    )

    static let resizeSplitDown = ToasttyKeyboardShortcut(
        .downArrow,
        modifiers: [.command, .control]
    )

    static let equalizeSplits = ToasttyKeyboardShortcut(
        "=",
        modifiers: [.command, .control]
    )

    static let previousWorkspace = ToasttyKeyboardShortcut(
        "[",
        modifiers: [.option, .shift]
    )

    static let nextWorkspace = ToasttyKeyboardShortcut(
        "]",
        modifiers: [.option, .shift]
    )
}
