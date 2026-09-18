import Foundation

/// One desktop workspace-annotation chip. The host resolves the key's color,
/// so its palette and per-key fallback stay the single source of truth and a
/// client only derives the chip's foreground, fill, and border from it.
public struct RemoteWorkspaceAnnotation: Codable, Equatable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var text: String
    /// Validated http or https link; absent for a text-only chip.
    public var url: URL?
    /// Resolved base chip color as `#RRGGBB`.
    public var color: String

    public init(key: String, text: String, url: URL? = nil, color: String) {
        self.key = key
        self.text = text
        self.url = url
        self.color = color
    }
}

/// Chip color derivation shared by the desktop sidebar and the iOS app, so the
/// same base color renders identically on both dark surfaces.
public enum WorkspaceAnnotationChipPalette {
    public static let backgroundAlpha = 0.14
    public static let borderAlpha = 0.42
    /// The neutral palette entry; used when a base color cannot be parsed.
    public static let fallbackBaseHex: UInt32 = 0xB7AEA5

    /// Blends dark hues toward white until chip text stays readable on a dark
    /// background.
    public static func readableForegroundHex(forBase hex: UInt32) -> UInt32 {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let minimumLuminance = 0.45
        guard luminance < minimumLuminance else { return hex }

        // Blend factor grows as the color gets darker; a pure-black chip text
        // becomes a mid gray rather than staying invisible.
        let blend = min(0.85, (minimumLuminance - luminance) / minimumLuminance + 0.25)
        func lightened(_ component: Double) -> UInt32 {
            UInt32((component + (1 - component) * blend) * 255)
        }
        return (lightened(red) << 16) | (lightened(green) << 8) | lightened(blue)
    }

    /// Uppercase `#RRGGBB` spelling of a 24-bit color.
    public static func hexString(_ hex: UInt32) -> String {
        let digits = String(hex & 0xFFFFFF, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// Parses `#RRGGBB` (case-insensitive); anything else is nil.
    public static func baseHex(fromColor color: String) -> UInt32? {
        guard color.hasPrefix("#"), color.count == 7 else { return nil }
        let digits = color.dropFirst()
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(digits, radix: 16)
    }
}
