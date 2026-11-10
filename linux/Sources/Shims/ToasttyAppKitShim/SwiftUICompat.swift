import Foundation

// The few SwiftUI value types the UI-free App layer names (keyboard shortcut
// descriptors, font weights for sidebar presentation). No views.

public struct KeyEquivalent: Hashable, Sendable, ExpressibleByExtendedGraphemeClusterLiteral {
    public let character: Character
    public init(_ character: Character) { self.character = character }
    public init(extendedGraphemeClusterLiteral value: Character) { character = value }

    public static let upArrow = KeyEquivalent("\u{F700}")
    public static let downArrow = KeyEquivalent("\u{F701}")
    public static let leftArrow = KeyEquivalent("\u{F702}")
    public static let rightArrow = KeyEquivalent("\u{F703}")
    public static let escape = KeyEquivalent("\u{1B}")
    public static let `return` = KeyEquivalent("\r")
    public static let tab = KeyEquivalent("\t")
    public static let space = KeyEquivalent(" ")
    public static let delete = KeyEquivalent("\u{8}")
    public static let deleteForward = KeyEquivalent("\u{F728}")
    public static let home = KeyEquivalent("\u{F729}")
    public static let end = KeyEquivalent("\u{F72B}")
    public static let pageUp = KeyEquivalent("\u{F72C}")
    public static let pageDown = KeyEquivalent("\u{F72D}")
    public static let clear = KeyEquivalent("\u{F739}")
}

public struct EventModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let capsLock = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let control = Self(rawValue: 1 << 2)
    public static let option = Self(rawValue: 1 << 3)
    public static let command = Self(rawValue: 1 << 4)
    public static let numericPad = Self(rawValue: 1 << 5)
    public static let function = Self(rawValue: 1 << 6)
    public static let all: Self = [.capsLock, .shift, .control, .option, .command, .numericPad, .function]
}

public enum Font {
    public struct Weight: Hashable, Sendable {
        /// CSS-style numeric weight (400 regular, 700 bold) for Pango/GTK.
        public let value: Int
        public init(value: Int) { self.value = value }
        public static let ultraLight = Weight(value: 100)
        public static let thin = Weight(value: 200)
        public static let light = Weight(value: 300)
        public static let regular = Weight(value: 400)
        public static let medium = Weight(value: 500)
        public static let semibold = Weight(value: 600)
        public static let bold = Weight(value: 700)
        public static let heavy = Weight(value: 800)
        public static let black = Weight(value: 900)
    }
}

/// Only `Text.TruncationMode`, for presentation models.
public enum Text {
    public enum TruncationMode: Hashable, Sendable {
        case head
        case tail
        case middle
    }
}

public struct UnitPoint: Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public static let zero = UnitPoint(x: 0, y: 0)
    public static let center = UnitPoint(x: 0.5, y: 0.5)
    public static let leading = UnitPoint(x: 0, y: 0.5)
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0)
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    public static let topLeading = UnitPoint(x: 0, y: 0)
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)
}

/// SwiftUI focused-value keys, so window-context declarations compile. The
/// GTK frontend tracks the focused window itself.
public protocol FocusedValueKey {
    associatedtype Value
}

public struct FocusedValues {
    private var storage: [ObjectIdentifier: Any] = [:]
    public init() {}

    public subscript<Key: FocusedValueKey>(key: Key.Type) -> Key.Value? {
        get { storage[ObjectIdentifier(key)] as? Key.Value }
        set { storage[ObjectIdentifier(key)] = newValue }
    }
}
