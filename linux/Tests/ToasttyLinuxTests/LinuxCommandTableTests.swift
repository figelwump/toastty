import CGtk
import Foundation
import Testing
@testable import ToasttyLinuxUI

@Suite("Linux command table")
struct LinuxCommandTableTests {
    static let repoRoot = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `ToasttyBuiltInCommand.id` values and which of them carry a macOS
    /// shortcut, parsed from the macOS source so the test follows it.
    static func macOSBuiltInCommands() throws -> (ids: [String], withShortcut: Set<String>) {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/App/Commands/ToasttyBuiltInCommand.swift"),
            encoding: .utf8
        )
        func body(of property: String) -> String {
            guard let start = source.range(of: "var \(property):") else { return "" }
            let rest = source[start.upperBound...]
            let end = rest.range(of: "\n    var ") ?? rest.range(of: "\n    static func ")
            return String(rest[..<(end?.lowerBound ?? rest.endIndex)])
        }

        // case name -> id
        var idByCase: [String: String] = [:]
        let idBody = body(of: "id")
        let caseIDPattern = try NSRegularExpression(pattern: #"case \.(\w+):\s*(?://[^\n]*\n\s*)*return "([^"]+)""#)
        for match in caseIDPattern.matches(in: idBody, range: NSRange(idBody.startIndex..., in: idBody)) {
            let name = String(idBody[Range(match.range(at: 1), in: idBody)!])
            let id = String(idBody[Range(match.range(at: 2), in: idBody)!])
            idByCase[name] = id
        }

        // Cases whose `shortcut` returns something other than nil.
        var withShortcut = Set<String>()
        let shortcutBody = body(of: "shortcut")
        let shortcutPattern = try NSRegularExpression(pattern: #"case ([\.\w, ]+):\s*return (\w+)"#)
        for match in shortcutPattern.matches(in: shortcutBody, range: NSRange(shortcutBody.startIndex..., in: shortcutBody)) {
            let names = String(shortcutBody[Range(match.range(at: 1), in: shortcutBody)!])
            let value = String(shortcutBody[Range(match.range(at: 2), in: shortcutBody)!])
            guard value != "nil" else { continue }
            for name in names.split(separator: ",") {
                let trimmed = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if let id = idByCase[trimmed] { withShortcut.insert(id) }
            }
        }
        return (idByCase.values.sorted(), withShortcut)
    }

    @Test func everyMacOSBuiltInCommandIsMapped() throws {
        let macOS = try Self.macOSBuiltInCommands()
        #expect(macOS.ids.count >= 50, "parser found too few built-in commands: \(macOS.ids.count)")
        let missing = macOS.ids.filter { LinuxCommandTable.binding($0) == nil }
        #expect(missing.isEmpty, "macOS commands without a Linux binding: \(missing)")
    }

    @Test func everyMacOSShortcutHasAnUbuntuAccelerator() throws {
        let macOS = try Self.macOSBuiltInCommands()
        #expect(macOS.withShortcut.count >= 30, "parser found too few shortcuts: \(macOS.withShortcut.count)")
        let dropped = macOS.withShortcut.filter { id in
            (LinuxCommandTable.binding(id)?.accelerators.isEmpty ?? true)
                && LinuxCommandTable.macOSShortcutsWithoutLinuxAccelerator.contains(id) == false
        }
        #expect(dropped.isEmpty, "macOS shortcuts with no Ubuntu accelerator: \(dropped.sorted())")
    }

    @Test func commandIDsAreUniqueValidActionNames() {
        let ids = LinuxCommandTable.all.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate command IDs")
        for id in ids {
            #expect(g_action_name_is_valid(id) != 0, "invalid GAction name \(id)")
        }
    }

    @Test func everyAcceleratorParses() {
        for binding in LinuxCommandTable.all {
            for accelerator in binding.accelerators {
                #expect(ParsedAccelerator(accelerator) != nil, "\(binding.id): cannot parse \(accelerator)")
            }
        }
    }

    @Test func noAcceleratorIsBoundTwice() {
        // Panel-scoped keys only fire inside their panel, but they still may
        // not collide with a global key or another panel key.
        let matcher = ShortcutMatcher(bindings: LinuxCommandTable.all)
        let duplicates = matcher.duplicateAccelerators()
        #expect(duplicates.isEmpty, "duplicate accelerators: \(duplicates.map { "\($0.key.label) -> \($0.value)" })")
    }

    @Test func planTableIsImplemented() {
        // docs/plans/linux-port.md "Keyboard shortcuts (Ubuntu mapping)".
        let expected: [String: String] = [
            "window.create": "<Control><Shift>n",
            "workspace.tab.create": "<Control><Shift>t",
            "panel.close": "<Control><Shift>w",
            "app.quit": "<Control><Shift>q",
            "window.toggle-sidebar": "F9",
            "window.toggle-right-panel": "<Shift>F9",
            "workspace.create": "<Control><Alt>n",
            "workspace.close": "<Control><Alt>w",
            "workspace.rename": "F2",
            "workspace.tab.rename": "<Shift>F2",
            "layout.split.horizontal": "<Control><Shift>o",
            "layout.split.vertical": "<Control><Shift>e",
            "layout.split.select-previous": "<Control><Alt>bracketleft",
            "layout.split.select-next": "<Control><Alt>bracketright",
            "layout.split.navigate-left": "<Alt>Left",
            "layout.split.resize-left": "<Control><Shift>Left",
            "layout.split.equalize": "<Control><Alt>equal",
            "panel.focus-mode.toggle": "<Control><Shift>x",
            "panel.focus-next-unread-or-active": "<Control><Shift>j",
            "session.later-flag.toggle": "<Control><Shift>l",
            "panel.process-watch.create": "<Control><Shift>m",
            "workspace.merge": "<Alt><Shift>m",
            "workspace.tab.select-1": "<Alt>1",
            "workspace.tab.select-9": "<Alt>9",
            "workspace.select-1": "<Control><Alt>1",
            "workspace.tab.select-previous": "<Control>Page_Up",
            "workspace.tab.select-next": "<Control>Page_Down",
            "workspace.tab.move-left": "<Control><Shift>Page_Up",
            "right-panel.tab.select-previous": "<Control><Alt>Page_Up",
            "layout.pane.focus-1": "<Alt><Shift>1",
            "layout.pane.focus-10": "<Alt><Shift>0",
            "browser.create": "<Control><Alt>b",
            "browser.tab.create": "<Control><Alt><Shift>b",
            "scratchpad.create": "<Control><Alt>s",
            "command-palette.toggle": "<Control><Shift>p",
            "find.show": "<Control><Shift>f",
            "find.next": "<Control><Shift>g",
            "find.previous": "<Control><Shift>h",
            "terminal.copy": "<Control><Shift>c",
            "terminal.paste": "<Control><Shift>v",
            "text-size.increase": "<Control>plus",
            "text-size.decrease": "<Control>minus",
            "text-size.reset": "<Control>0",
            "browser.location.focus": "<Control>l",
            "browser.reload": "<Control>r",
            "local-document.edit": "<Control>e",
            "local-document.save": "<Control>s",
            "app.preferences": "<Control>comma",
            "app.shortcuts": "<Control>question",
            "window.fullscreen": "F11",
        ]
        for (id, accelerator) in expected {
            let binding = LinuxCommandTable.binding(id)
            #expect(binding?.accelerators.contains(accelerator) == true, "\(id) should include \(accelerator), has \(binding?.accelerators ?? [])")
        }
        #expect(LinuxCommandTable.binding("find.next")?.accelerators.contains("F3") == true)
        #expect(LinuxCommandTable.binding("terminal.paste")?.accelerators.contains("<Shift>Insert") == true)
        #expect(LinuxCommandTable.binding("browser.reload")?.accelerators.contains("F5") == true)
    }

    @Test func terminalOwnedKeysAreNeverGlobal() {
        // Plain Ctrl+<letter> belongs to the shell.
        for binding in LinuxCommandTable.globalBindings {
            for accelerator in binding.accelerators {
                guard let parsed = ParsedAccelerator(accelerator) else { continue }
                let isLetter = gdk_keyval_to_upper(parsed.keyval) != parsed.keyval
                let plainControl = parsed.modifiers == GDK_CONTROL_MASK.rawValue
                #expect((isLetter && plainControl) == false, "\(binding.id) steals \(accelerator) from the terminal")
            }
        }
        for id in ["browser.location.focus", "browser.reload", "local-document.edit", "local-document.save"] {
            #expect(LinuxCommandTable.binding(id)?.scope == .panel)
        }
        #expect(LinuxCommandTable.binding("terminal.copy")?.scope == .terminal)
    }

    @Test func profileAcceleratorsAvoidReservedKeys() {
        #expect(LinuxCommandTable.profileAccelerator(shortcutKey: "c", splitDown: false) == "<Control><Alt>c")
        #expect(LinuxCommandTable.profileAccelerator(shortcutKey: "C", splitDown: true) == "<Control><Alt><Shift>c")
        for key in ["n", "w", "b", "s", "1", "0"] {
            #expect(LinuxCommandTable.profileAccelerator(shortcutKey: key, splitDown: false) == nil)
        }
        let matcher = ShortcutMatcher(bindings: LinuxCommandTable.all)
        for letter in "acdefghijklmopqrtuvxyz" {
            guard let accelerator = LinuxCommandTable.profileAccelerator(shortcutKey: String(letter), splitDown: false),
                  let parsed = ParsedAccelerator(accelerator) else { continue }
            #expect(matcher.entries.contains { $0.accelerator == parsed } == false, "profile key \(letter) collides")
        }
    }

    @MainActor @Test func menuReferencesOnlyKnownCommands() {
        for section in LinuxMenus.layout {
            for group in section {
                for id in group.items {
                    #expect(LinuxCommandTable.binding(id) != nil, "menu item \(id) unknown")
                }
            }
        }
    }

    @MainActor @Test func safeAcceleratorsExcludeEditingKeys() {
        #expect(LinuxAppController.isSafeAccelerator(["<Control><Shift>t"]))
        #expect(LinuxAppController.isSafeAccelerator(["F9"]))
        #expect(LinuxAppController.isSafeAccelerator(["<Shift>F2"]))
        #expect(LinuxAppController.isSafeAccelerator(["<Control><Shift>Left"]) == false)
        #expect(LinuxAppController.isSafeAccelerator(["<Alt>1"]) == false)
        #expect(LinuxAppController.isSafeAccelerator(["<Control>Page_Up"]) == false)
    }
}

@Suite("Shortcut matcher")
struct ShortcutMatcherTests {
    let matcher = ShortcutMatcher(bindings: LinuxCommandTable.globalBindings)
    let control = GDK_CONTROL_MASK.rawValue
    let shift = GDK_SHIFT_MASK.rawValue
    let alt = GDK_ALT_MASK.rawValue

    func key(_ name: String) -> UInt32 { gdk_keyval_from_name(name) }

    @Test func controlShiftLetter() {
        // Ctrl+Shift+L arrives as keyval "L" with shift consumed.
        #expect(matcher.match(keyval: key("L"), unshiftedKeyval: key("l"), state: control | shift, consumed: shift) == "session.later-flag.toggle")
        #expect(matcher.match(keyval: key("P"), unshiftedKeyval: key("p"), state: control | shift, consumed: shift) == "command-palette.toggle")
    }

    @Test func plainControlLetterIsNotMatched() {
        #expect(matcher.match(keyval: key("l"), unshiftedKeyval: key("l"), state: control, consumed: 0) == nil)
        #expect(matcher.match(keyval: key("c"), unshiftedKeyval: key("c"), state: control, consumed: 0) == nil)
    }

    @Test func shiftedSymbolUsesConsumedShift() {
        // Ctrl+Shift+/ produces "question".
        #expect(matcher.match(keyval: key("question"), unshiftedKeyval: key("slash"), state: control | shift, consumed: shift) == "app.shortcuts")
        // Ctrl+Shift+= produces "plus".
        #expect(matcher.match(keyval: key("plus"), unshiftedKeyval: key("equal"), state: control | shift, consumed: shift) == "text-size.increase")
        #expect(matcher.match(keyval: key("equal"), unshiftedKeyval: key("equal"), state: control, consumed: 0) == "text-size.increase")
    }

    @Test func altShiftDigitMatchesPhysicalKey() {
        // Alt+Shift+1 arrives as "exclam" on US layouts.
        #expect(matcher.match(keyval: key("exclam"), unshiftedKeyval: key("1"), state: alt | shift, consumed: shift) == "layout.pane.focus-1")
        #expect(matcher.match(keyval: key("parenright"), unshiftedKeyval: key("0"), state: alt | shift, consumed: shift) == "layout.pane.focus-10")
        #expect(matcher.match(keyval: key("1"), unshiftedKeyval: key("1"), state: alt, consumed: 0) == "workspace.tab.select-1")
        #expect(matcher.match(keyval: key("1"), unshiftedKeyval: key("1"), state: control | alt, consumed: 0) == "workspace.select-1")
    }

    @Test func pageKeysDistinguishModifiers() {
        #expect(matcher.match(keyval: key("Page_Up"), unshiftedKeyval: key("Page_Up"), state: control, consumed: 0) == "workspace.tab.select-previous")
        #expect(matcher.match(keyval: key("Page_Up"), unshiftedKeyval: key("Page_Up"), state: control | shift, consumed: 0) == "workspace.tab.move-left")
        #expect(matcher.match(keyval: key("Page_Down"), unshiftedKeyval: key("Page_Down"), state: control | alt, consumed: 0) == "right-panel.tab.select-next")
    }

    @Test func functionKeys() {
        #expect(matcher.match(keyval: key("F9"), unshiftedKeyval: key("F9"), state: 0, consumed: 0) == "window.toggle-sidebar")
        #expect(matcher.match(keyval: key("F9"), unshiftedKeyval: key("F9"), state: shift, consumed: 0) == "window.toggle-right-panel")
        #expect(matcher.match(keyval: key("F2"), unshiftedKeyval: key("F2"), state: 0, consumed: 0) == "workspace.rename")
    }

    @Test func labelsAreReadable() {
        #expect(ShortcutLabels.label(forCommand: "workspace.select-1") == "Ctrl+Alt+1")
        #expect(ShortcutLabels.label(forCommand: "window.toggle-sidebar") == "F9")
    }
}
