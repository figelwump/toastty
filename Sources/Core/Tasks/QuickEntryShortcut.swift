import Foundation

/// The global shortcut that opens the quick entry panel, parsed from
/// `[quick_entry] shortcut` in `tasks.toml`, for example `"opt+shift+t"`.
///
/// It names a key by the character a US keyboard types, so the app can map
/// it to a physical key without reading the current keyboard layout.
public struct QuickEntryShortcut: Equatable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public enum Key: Equatable, Hashable, Sendable {
        /// A lowercase letter, a digit, or one of ``punctuation``.
        case character(Character)
        case space
        case `return`
        case tab
        /// F1 to F20.
        case function(Int)

        public static let punctuation: Set<Character> = ["-", "=", "[", "]", ";", "'", ",", ".", "/", "\\", "`"]
        public static let functionKeyRange = 1...20
    }

    public struct ParseError: LocalizedError, Equatable, Sendable {
        public let message: String

        public var errorDescription: String? { message }
    }

    public var modifiers: Modifiers
    public var key: Key

    public init(modifiers: Modifiers, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// ⌥⇧T.
    public static let `default` = QuickEntryShortcut(modifiers: [.option, .shift], key: .character("t"))

    /// The shortcut as a menu shows it, such as `⌥⇧T`, with modifiers in
    /// the order macOS uses.
    public var symbolLabel: String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        switch key {
        case .character(let character):
            label += character.uppercased()
        case .space:
            label += "Space"
        case .return:
            label += "↩"
        case .tab:
            label += "⇥"
        case .function(let number):
            label += "F\(number)"
        }
        return label
    }

    private static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command,
        "ctrl": .control, "control": .control,
        "opt": .option, "option": .option, "alt": .option,
        "shift": .shift,
    ]

    /// Parses parts joined by `+`: modifiers first, then one key. Case and
    /// blank space around the parts do not matter.
    public static func parse(_ text: String) throws -> QuickEntryShortcut {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.contains(where: \.isEmpty) == false else {
            throw ParseError(message: "the shortcut \"\(text)\" has an empty part; join its keys with +, as in \"opt+shift+t\"")
        }
        guard let keyName = parts.last else {
            throw ParseError(message: "the shortcut is empty")
        }
        guard modifierNames[keyName] == nil else {
            throw ParseError(message: "the shortcut \"\(text)\" ends with a modifier; end it with a key, as in \"opt+shift+t\"")
        }

        var modifiers: Modifiers = []
        for name in parts.dropLast() {
            guard let modifier = modifierNames[name] else {
                throw ParseError(message: "the shortcut \"\(text)\" has an unknown modifier \"\(name)\"; use cmd, ctrl, opt or shift")
            }
            guard modifiers.contains(modifier) == false else {
                throw ParseError(message: "the shortcut \"\(text)\" names \(name) twice")
            }
            modifiers.insert(modifier)
        }

        guard let key = Self.key(named: keyName) else {
            throw ParseError(message: "the shortcut \"\(text)\" has an unknown key \"\(keyName)\"; use a letter, a digit, punctuation, space, return, tab or f1 to f20")
        }
        // A shortcut is global: without one of these it would take ordinary
        // typing away from every app. A function key alone is not typed text.
        if case .function = key {
        } else if modifiers.isDisjoint(with: [.command, .control, .option]) {
            throw ParseError(message: "the shortcut \"\(text)\" needs Command, Control or Option, so it does not catch ordinary typing")
        }
        return QuickEntryShortcut(modifiers: modifiers, key: key)
    }

    private static func key(named name: String) -> Key? {
        switch name {
        case "space": return .space
        case "return", "enter": return .return
        case "tab": return .tab
        default: break
        }
        if name.count == 1, let character = name.first {
            if character.isASCII, character.isLetter || character.isNumber || Key.punctuation.contains(character) {
                return .character(character)
            }
            return nil
        }
        if name.hasPrefix("f"), let number = Int(name.dropFirst()), Key.functionKeyRange.contains(number),
           String(number) == name.dropFirst() {
            return .function(number)
        }
        return nil
    }
}
