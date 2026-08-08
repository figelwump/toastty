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
}

/// Global per-key annotation colors, shared across workspaces and layout
/// profiles within one runtime home. The store is app-owned: the CLI executor
/// mutates it and the sidebar observes it, so a color-only change restyles
/// every chip with that key immediately.
@MainActor
final class AnnotationStyleStore: ObservableObject {
    static let fileName = "annotation-styles.json"

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

    /// Stable palette selection for keys without an explicit style. FNV-1a
    /// over UTF-8 bytes, never Swift `hashValue`, so the same key renders the
    /// same color across workspaces, profiles, and launches.
    nonisolated static func fallbackColorToken(forKey key: String) -> AnnotationColorToken {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let palette = AnnotationColorToken.NamedColor.allCases
        return .named(palette[Int(hash % UInt64(palette.count))])
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
