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
        "\(modifiers.symbolLabel)\(key.displaySymbol)"
    }

    func helpText(_ title: String) -> String {
        "\(title) (\(symbolLabel))"
    }

    // AppKit uses a tab-delimited trailing column for menu shortcut text.
    // This shows the hint in contextual menus without rebinding the shortcut.
    func menuTitle(_ title: String) -> String {
        "\(title)\t\(symbolLabel)"
    }

    static func displaySymbol(forMenuKeyEquivalent keyEquivalent: String) -> String {
        guard let character = keyEquivalent.first else {
            return ""
        }
        return displaySymbol(for: character)
    }

    fileprivate static func displaySymbol(for character: Character) -> String {
        let scalarValue = String(character).unicodeScalars.first?.value
        switch scalarValue {
        case 0xF702: return "\u{2190}"
        case 0xF703: return "\u{2192}"
        case 0xF700: return "\u{2191}"
        case 0xF701: return "\u{2193}"
        case 0x001B: return "\u{238B}"
        case 0x000D: return "\u{21A9}"
        case 0x0009: return "\u{21E5}"
        case 0x0020: return "\u{2423}"
        case 0x0008, 0x007F: return "\u{232B}"
        default: return String(character).uppercased()
        }
    }
}

private extension KeyEquivalent {
    // KeyEquivalent's arrow constants use private-use Unicode codepoints that
    // most UI fonts can't render (shows up as a missing-glyph box or "?").
    // Map them (and other common special keys) to display glyphs.
    var displaySymbol: String {
        ToasttyKeyboardShortcut.displaySymbol(for: character)
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
    static let commandPalette = ToasttyKeyboardShortcut(
        "p",
        modifiers: [.command, .shift]
    )

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

    static let toggleRightPanel = ToasttyKeyboardShortcut(
        "b",
        modifiers: [.command, .option]
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

    static let selectPreviousTab = ToasttyKeyboardShortcut(
        "[",
        modifiers: [.command, .shift]
    )

    static let selectNextTab = ToasttyKeyboardShortcut(
        "]",
        modifiers: [.command, .shift]
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

    static let watchRunningCommand = ToasttyKeyboardShortcut(
        "m",
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

    static let increaseTextSize = ToasttyKeyboardShortcut(
        "+",
        modifiers: [.command]
    )

    static let decreaseTextSize = ToasttyKeyboardShortcut(
        "-",
        modifiers: [.command]
    )

    static let resetTextSize = ToasttyKeyboardShortcut(
        "0",
        modifiers: [.command]
    )

    static let focusNextUnreadOrActivePanel = ToasttyKeyboardShortcut(
        "a",
        modifiers: [.command, .shift]
    )

    static let toggleLaterFlag = ToasttyKeyboardShortcut(
        "l",
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

    static let focusPaneLeft = ToasttyKeyboardShortcut(
        .leftArrow,
        modifiers: [.command, .option]
    )

    static let focusPaneRight = ToasttyKeyboardShortcut(
        .rightArrow,
        modifiers: [.command, .option]
    )

    static let focusPaneUp = ToasttyKeyboardShortcut(
        .upArrow,
        modifiers: [.command, .option]
    )

    static let focusPaneDown = ToasttyKeyboardShortcut(
        .downArrow,
        modifiers: [.command, .option]
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
