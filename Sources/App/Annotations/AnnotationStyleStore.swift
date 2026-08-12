import CoreState
import Foundation

/// A workspace-annotation chip color: one of the six named palette entries or
/// an arbitrary `#RRGGBB` value. The token's storage string is the public CLI
/// and persistence representation.
enum AnnotationColorToken: Equatable, Hashable, Sendable {
    enum NamedColor: String, CaseIterable, Equatable, Sendable {
        case neutral
        case green
        case amber
        case red
        case violet
        case blue
    }

    case named(NamedColor)
    case hex(String)

    /// Parses a CLI/persisted token: a named color or `#RRGGBB`
    /// (case-insensitive; normalized to uppercase). Invalid tokens are nil.
    static func parse(_ rawValue: String) -> AnnotationColorToken? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let named = NamedColor(rawValue: trimmed.lowercased()) {
            return .named(named)
        }
        guard trimmed.hasPrefix("#"), trimmed.count == 7 else { return nil }
        let digits = trimmed.dropFirst().uppercased()
        let hexDigits = Set("0123456789ABCDEF")
        guard digits.allSatisfy(hexDigits.contains) else { return nil }
        return .hex("#\(digits)")
    }

    var storageValue: String {
        switch self {
        case .named(let named):
            return named.rawValue
        case .hex(let value):
            return value
        }
    }

    /// Fixed sRGB base used to render and compare tokens. Equality here is
    /// visual, so a named token and its exact hex spelling are equivalent.
    var baseHexValue: UInt32 {
        switch self {
        case .named(let named):
            switch named {
            case .neutral:
                return 0xB7AEA5
            case .green:
                return 0x5BA08A
            case .amber:
                return 0xE8A635
            case .red:
                return 0xE55C5C
            case .violet:
                return 0xA78BFA
            case .blue:
                return 0x7AA2F7
            }
        case .hex(let value):
            return UInt32(value.dropFirst(), radix: 16) ?? 0xB7AEA5
        }
    }

    func isVisuallyEquivalent(to other: AnnotationColorToken) -> Bool {
        baseHexValue == other.baseHexValue
    }
}

enum AnnotationStyleStoreError: LocalizedError {
    case automaticColorSpaceExhausted

    var errorDescription: String? {
        switch self {
        case .automaticColorSpaceExhausted:
            return "automatic annotation color space is exhausted"
        }
    }
}

/// Global per-key annotation colors, shared across workspaces and layout
/// profiles within one runtime home. The store is app-owned: the CLI executor
/// mutates it and the sidebar observes it, so a color-only change restyles
/// every chip with that key immediately.
@MainActor
final class AnnotationStyleStore: ObservableObject {
    static let fileName = "annotation-styles.json"
    private nonisolated static let automaticColorCombinationCount = 221 * 17 * 11

    @Published private(set) var colorTokensByKey: [String: AnnotationColorToken] = [:]

    private let fileURL: URL
    private let fileManager: FileManager

    init(runtimePaths: ToasttyRuntimePaths, fileManager: FileManager = .default) {
        // The runtime-path config directory keeps dev/test instances isolated;
        // never resolve a hard-coded home path here.
        fileURL = runtimePaths.configDirectoryURL
            .appending(path: Self.fileName, directoryHint: .notDirectory)
        self.fileManager = fileManager
        colorTokensByKey = Self.loadColorTokens(from: fileURL)
    }

    /// The effective token for a key: the explicit global style when one
    /// exists, otherwise the deterministic fallback.
    func effectiveColorToken(forKey key: String) -> AnnotationColorToken {
        colorTokensByKey[key] ?? Self.fallbackColorToken(forKey: key)
    }

    /// Runtime-global historical keys in deterministic bytewise order. Keys
    /// admitted through app-control and persisted-load boundaries are
    /// canonical lowercase ASCII, so Swift's lexical ordering is bytewise here.
    func registeredKeys() -> [String] {
        colorTokensByKey.keys.sorted()
    }

    /// Stable first automatic candidate for a key. Claims are materialized in
    /// the style file; allocation probes the same safe color space when this
    /// candidate is already owned by another key.
    nonisolated static func fallbackColorToken(forKey key: String) -> AnnotationColorToken {
        automaticColorCandidate(forKey: key, probe: 0)
    }

    /// Allocates a deterministic automatic color that is visually distinct
    /// from every recorded claim. Explicit callers may intentionally reuse a
    /// semantic color; this uniqueness rule applies only to automatic claims.
    nonisolated static func automaticColorToken(
        forKey key: String,
        avoiding claimedBaseHexValues: Set<UInt32>
    ) throws -> AnnotationColorToken {
        let candidateCount = 1 + automaticColorCombinationCount
        for probe in 0..<candidateCount {
            let candidate = automaticColorCandidate(forKey: key, probe: probe)
            if claimedBaseHexValues.contains(candidate.baseHexValue) == false {
                return candidate
            }
        }
        throw AnnotationStyleStoreError.automaticColorSpaceExhausted
    }

    private nonisolated static func automaticColorCandidate(
        forKey key: String,
        probe: Int
    ) -> AnnotationColorToken {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }

        let hue: Double
        let saturation: Double
        let lightness: Double
        if probe == 0 {
            hue = 80 + Double(hash % 221)
            saturation = 0.52 + (Double((hash >> 8) % 17) / 100)
            lightness = 0.58 + (Double((hash >> 16) % 11) / 100)
        } else {
            // Exhaustively rotate through the bounded green-through-magenta
            // HSL space after trying the historical per-key fallback first.
            var index = (
                Int(hash % UInt64(automaticColorCombinationCount)) + probe - 1
            ) % automaticColorCombinationCount
            hue = 80 + Double(index % 221)
            index /= 221
            saturation = 0.52 + (Double(index % 17) / 100)
            index /= 17
            lightness = 0.58 + (Double(index % 11) / 100)
        }
        return .hex(hslHex(hue: hue, saturation: saturation, lightness: lightness))
    }

    private nonisolated static func hslHex(
        hue: Double,
        saturation: Double,
        lightness: Double
    ) -> String {
        let chroma = (1 - abs((2 * lightness) - 1)) * saturation
        let hueSector = hue / 60
        let secondary = chroma * (1 - abs(hueSector.truncatingRemainder(dividingBy: 2) - 1))
        let components: (red: Double, green: Double, blue: Double)
        switch hueSector {
        case 0..<1:
            components = (chroma, secondary, 0)
        case 1..<2:
            components = (secondary, chroma, 0)
        case 2..<3:
            components = (0, chroma, secondary)
        case 3..<4:
            components = (0, secondary, chroma)
        case 4..<5:
            components = (secondary, 0, chroma)
        default:
            components = (chroma, 0, secondary)
        }

        let match = lightness - (chroma / 2)
        func byte(_ component: Double) -> Int {
            Int(((component + match) * 255).rounded())
        }
        return String(
            format: "#%02X%02X%02X",
            byte(components.red),
            byte(components.green),
            byte(components.blue)
        )
    }

    /// Applies a global color for a key. Returns whether the style actually
    /// changed; throws when persisting fails, in which case neither disk nor
    /// the observed in-memory map is mutated.
    @discardableResult
    func setColor(_ token: AnnotationColorToken, forKey key: String) throws -> Bool {
        guard colorTokensByKey[key] != token else { return false }
        var candidateTokens = colorTokensByKey
        candidateTokens[key] = token
        try persist(candidateTokens)
        colorTokensByKey = candidateTokens
        return true
    }

    /// Atomically records automatic claims for legacy/restored annotations
    /// that predate first-use materialization. Existing entries are preserved;
    /// new keys are allocated in bytewise order for repeatable migration.
    @discardableResult
    func materializeMissingClaims(forKeys keys: Set<String>) throws -> Bool {
        let missingKeys = keys
            .filter { colorTokensByKey[$0] == nil }
            .sorted()
        guard missingKeys.isEmpty == false else { return false }

        var candidateTokens = colorTokensByKey
        var claimedBaseHexValues = Set(candidateTokens.values.map(\.baseHexValue))
        for key in missingKeys {
            let token = try Self.automaticColorToken(
                forKey: key,
                avoiding: claimedBaseHexValues
            )
            candidateTokens[key] = token
            claimedBaseHexValues.insert(token.baseHexValue)
        }

        try persist(candidateTokens)
        colorTokensByKey = candidateTokens
        return true
    }

    // MARK: - Persistence

    private func persist(_ tokens: [String: AnnotationColorToken]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let storageMap = tokens.reduce(into: [String: String]()) { partialResult, entry in
            partialResult[entry.key] = entry.value.storageValue
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(storageMap)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func loadColorTokens(from fileURL: URL) -> [String: AnnotationColorToken] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return [:]
        }
        let storageMap: [String: String]
        do {
            storageMap = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            ToasttyLog.warning(
                "Ignoring corrupt annotation style file",
                category: .state,
                metadata: [
                    "path": fileURL.path,
                    "error": error.localizedDescription,
                ]
            )
            return [:]
        }

        return storageMap.reduce(into: [:]) { partialResult, entry in
            guard WorkspaceAnnotation.canonicalKey(entry.key) == entry.key,
                  let token = AnnotationColorToken.parse(entry.value) else {
                ToasttyLog.warning(
                    "Ignoring invalid annotation style entry",
                    category: .state,
                    metadata: [
                        "path": fileURL.path,
                        "key_length": String(entry.key.count),
                    ]
                )
                return
            }
            partialResult[entry.key] = token
        }
    }
}
