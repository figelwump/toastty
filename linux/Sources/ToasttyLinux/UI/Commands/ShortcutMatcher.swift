import CGtk

/// A parsed GTK accelerator.
public struct ParsedAccelerator: Hashable, Sendable {
    public let keyval: UInt32
    public let modifiers: UInt32

    public init?(_ accelerator: String) {
        var keyval: guint = 0
        var modifiers = GdkModifierType(rawValue: 0)
        gtk_accelerator_parse(accelerator, &keyval, &modifiers)
        guard keyval != 0 else { return nil }
        self.keyval = gdk_keyval_to_lower(keyval)
        self.modifiers = modifiers.rawValue & ShortcutMatcher.modifierMask
    }

    public init(keyval: UInt32, modifiers: UInt32) {
        self.keyval = gdk_keyval_to_lower(keyval)
        self.modifiers = modifiers & ShortcutMatcher.modifierMask
    }

    /// Localized label, e.g. "Ctrl+Shift+P".
    public var label: String {
        guard let cString = gtk_accelerator_get_label(keyval, GdkModifierType(rawValue: modifiers)) else { return "" }
        defer { g_free(cString) }
        return String(cString: cString)
    }
}

/// Matches key presses against the command table. Pure apart from GDK
/// keyval helpers, so it is unit-testable without a display.
public struct ShortcutMatcher: Sendable {
    public static let modifierMask: UInt32 =
        GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue

    public struct Entry: Sendable {
        public let accelerator: ParsedAccelerator
        public let commandID: String
    }

    public private(set) var entries: [Entry] = []

    public init(bindings: [LinuxCommandBinding]) {
        for binding in bindings {
            for accelerator in binding.accelerators {
                if let parsed = ParsedAccelerator(accelerator) {
                    entries.append(Entry(accelerator: parsed, commandID: binding.id))
                }
            }
        }
    }

    public mutating func add(accelerator: String, commandID: String) {
        if let parsed = ParsedAccelerator(accelerator) {
            entries.append(Entry(accelerator: parsed, commandID: commandID))
        }
    }

    /// - Parameters:
    ///   - keyval: the event keyval (shift level applied).
    ///   - unshiftedKeyval: the keyval of the same physical key at level 0,
    ///     so `<Alt><Shift>1` matches although the event says `exclam`.
    ///   - state: the event modifier state.
    ///   - consumed: modifiers the layout consumed to produce `keyval`
    ///     (shift for `question`, `plus`), so `<Control>question` matches
    ///     Ctrl+Shift+/ the way GTK accelerators do.
    public func match(keyval: UInt32, unshiftedKeyval: UInt32?, state: UInt32, consumed: UInt32) -> String? {
        let pressed = gdk_keyval_to_lower(keyval)
        let unshifted = unshiftedKeyval.map { gdk_keyval_to_lower($0) }
        let state = state & Self.modifierMask
        var consumed = consumed & Self.modifierMask
        // Shift is significant for cased letters: Ctrl+Shift+L is not Ctrl+L.
        if gdk_keyval_to_upper(pressed) != pressed {
            consumed &= ~GDK_SHIFT_MASK.rawValue
        }

        // 1. Exact keyval and exact modifiers.
        for entry in entries where entry.accelerator.keyval == pressed && entry.accelerator.modifiers == state {
            return entry.commandID
        }
        // 2. Physical key at level 0 with every modifier significant, so
        //    `<Alt><Shift>1` matches although the event keyval is `exclam`.
        if let unshifted, unshifted != pressed {
            for entry in entries where entry.accelerator.keyval == unshifted && entry.accelerator.modifiers == state {
                return entry.commandID
            }
        }
        // 3. Exact keyval with consumed modifiers ignored (GTK accelerator
        //    rule), so `<Control>question` matches Ctrl+Shift+/.
        for entry in entries where entry.accelerator.keyval == pressed {
            if (entry.accelerator.modifiers & ~consumed) == (state & ~consumed) {
                return entry.commandID
            }
        }
        return nil
    }

    /// Accelerators bound to more than one command.
    public func duplicateAccelerators() -> [ParsedAccelerator: [String]] {
        var map: [ParsedAccelerator: [String]] = [:]
        for entry in entries {
            map[entry.accelerator, default: []].append(entry.commandID)
        }
        return map.filter { Set($0.value).count > 1 }
    }
}

public enum ShortcutLabels {
    public static func label(forCommand id: String) -> String? {
        guard let accelerator = LinuxCommandTable.binding(id)?.primaryAccelerator else { return nil }
        return ParsedAccelerator(accelerator)?.label
    }
}
