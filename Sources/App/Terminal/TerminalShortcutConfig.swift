import Foundation

enum TerminalShortcutConfig {
    static let maxShortcutCount = 10

    static func shortcutNumber(from charactersIgnoringModifiers: String?) -> Int? {
        guard let charactersIgnoringModifiers, charactersIgnoringModifiers.count == 1 else {
            return nil
        }

        switch charactersIgnoringModifiers {
        case "1":
            return 1
        case "2":
            return 2
        case "3":
            return 3
        case "4":
            return 4
        case "5":
            return 5
        case "6":
            return 6
        case "7":
            return 7
        case "8":
            return 8
        case "9":
            return 9
        case "0":
            return 10
        default:
            return nil
        }
    }

    static func shortcutLabel(for number: Int) -> String? {
        switch number {
        case 1 ... 9:
            return "⌥⇧\(number)"
        case 10:
            return "⌥⇧0"
        default:
            return nil
        }
    }
}
