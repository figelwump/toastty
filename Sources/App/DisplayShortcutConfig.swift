import AppKit
import Carbon.HIToolbox
import Foundation

enum DisplayShortcutScope {
    case workspaceSwitch
    case panelFocus

    fileprivate var requiredModifiers: NSEvent.ModifierFlags {
        switch self {
        case .workspaceSwitch:
            return [.option]
        case .panelFocus:
            return [.option, .shift]
        }
    }

    fileprivate var symbolLabel: String {
        switch self {
        case .workspaceSwitch:
            return "⌥"
        case .panelFocus:
            return "⌥⇧"
        }
    }
}

enum DisplayShortcutConfig {
    static let maxWorkspaceShortcutCount = 9
    static let maxPanelFocusShortcutCount = 10

    private static let supportedModifiers: NSEvent.ModifierFlags = [
        .command,
        .control,
        .option,
        .shift,
    ]

    static func shortcutNumber(for event: NSEvent, scope: DisplayShortcutScope) -> Int? {
        let flags = event.modifierFlags.intersection(supportedModifiers)
        guard flags == scope.requiredModifiers else { return nil }
        return shortcutNumber(forKeyCode: event.keyCode)
    }

    static func workspaceSwitchShortcutLabel(for number: Int) -> String? {
        shortcutLabel(for: number, scope: .workspaceSwitch, limit: maxWorkspaceShortcutCount)
    }

    static func panelFocusShortcutLabel(for number: Int) -> String? {
        shortcutLabel(for: number, scope: .panelFocus, limit: maxPanelFocusShortcutCount)
    }

    private static func shortcutNumber(forKeyCode keyCode: UInt16) -> Int? {
        switch Int(keyCode) {
        case Int(kVK_ANSI_1), Int(kVK_ANSI_Keypad1):
            return 1
        case Int(kVK_ANSI_2), Int(kVK_ANSI_Keypad2):
            return 2
        case Int(kVK_ANSI_3), Int(kVK_ANSI_Keypad3):
            return 3
        case Int(kVK_ANSI_4), Int(kVK_ANSI_Keypad4):
            return 4
        case Int(kVK_ANSI_5), Int(kVK_ANSI_Keypad5):
            return 5
        case Int(kVK_ANSI_6), Int(kVK_ANSI_Keypad6):
            return 6
        case Int(kVK_ANSI_7), Int(kVK_ANSI_Keypad7):
            return 7
        case Int(kVK_ANSI_8), Int(kVK_ANSI_Keypad8):
            return 8
        case Int(kVK_ANSI_9), Int(kVK_ANSI_Keypad9):
            return 9
        case Int(kVK_ANSI_0), Int(kVK_ANSI_Keypad0):
            return 10
        default:
            return nil
        }
    }

    private static func shortcutLabel(
        for number: Int,
        scope: DisplayShortcutScope,
        limit: Int
    ) -> String? {
        guard number > 0, number <= limit else { return nil }
        guard let keyLabel = keyLabel(for: number) else { return nil }
        return "\(scope.symbolLabel)\(keyLabel)"
    }

    private static func keyLabel(for number: Int) -> String? {
        switch number {
        case 1 ... 9:
            return "\(number)"
        case 10:
            return "0"
        default:
            return nil
        }
    }
}
