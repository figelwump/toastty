import CoreState
import Testing

struct QuickEntryShortcutTests {
    private func parse(_ text: String) throws -> QuickEntryShortcut {
        try QuickEntryShortcut.parse(text)
    }

    private func parseError(_ text: String) -> String? {
        do {
            _ = try parse(text)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test
    func parsesTheDefault() throws {
        let shortcut = try parse("opt+shift+t")
        #expect(shortcut == QuickEntryShortcut.default)
        #expect(shortcut.modifiers == [.option, .shift])
        #expect(shortcut.key == .character("t"))
        #expect(shortcut.symbolLabel == "⌥⇧T")
    }

    @Test
    func acceptsModifierAliasesInAnyCaseAndOrderWithSpaces() throws {
        #expect(try parse("Shift + Option + T") == QuickEntryShortcut.default)
        #expect(try parse("alt+SHIFT+t") == QuickEntryShortcut.default)
        #expect(try parse("command+control+n").modifiers == [.command, .control])
        #expect(try parse("cmd+ctrl+n").modifiers == [.command, .control])
    }

    @Test
    func labelsModifiersInMacOrder() throws {
        #expect(try parse("cmd+shift+opt+ctrl+k").symbolLabel == "⌃⌥⇧⌘K")
    }

    @Test
    func parsesNamedKeysDigitsAndPunctuation() throws {
        #expect(try parse("ctrl+opt+space").key == .space)
        #expect(try parse("ctrl+opt+space").symbolLabel == "⌃⌥Space")
        #expect(try parse("cmd+opt+return").key == .return)
        #expect(try parse("cmd+opt+enter").key == .return)
        #expect(try parse("cmd+opt+tab").key == .tab)
        #expect(try parse("ctrl+opt+1").key == .character("1"))
        #expect(try parse("cmd+opt+/").key == .character("/"))
        #expect(try parse("ctrl+f5").key == .function(5))
        #expect(try parse("ctrl+f5").symbolLabel == "⌃F5")
    }

    @Test
    func allowsAFunctionKeyWithoutModifiers() throws {
        let shortcut = try parse("f13")
        #expect(shortcut.modifiers.isEmpty)
        #expect(shortcut.key == .function(13))
    }

    @Test
    func refusesShortcutsThatWouldCatchOrdinaryTyping() {
        #expect(parseError("t")?.contains("Command, Control or Option") == true)
        #expect(parseError("shift+t")?.contains("Command, Control or Option") == true)
        #expect(parseError("shift+space")?.contains("Command, Control or Option") == true)
    }

    @Test
    func refusesMalformedShortcuts() {
        #expect(parseError("opt+shift")?.contains("ends with a modifier") == true)
        #expect(parseError("opt+shift+tt")?.contains("unknown key \"tt\"") == true)
        #expect(parseError("hyper+t")?.contains("unknown modifier \"hyper\"") == true)
        #expect(parseError("opt+opt+t")?.contains("names opt twice") == true)
        #expect(parseError("opt+option+t")?.contains("names option twice") == true)
        #expect(parseError("opt++t")?.contains("empty part") == true)
        #expect(parseError("ctrl+f21")?.contains("unknown key \"f21\"") == true)
        #expect(parseError("ctrl+f0")?.contains("unknown key \"f0\"") == true)
        #expect(parseError("ctrl+é")?.contains("unknown key") == true)
    }
}
