import CoreState
import Foundation

struct CommandPaletteUsageRecord: Codable, Equatable, Sendable {
    var count: Int
}

@MainActor
protocol CommandPaletteUsageTracking: AnyObject {
    func useCount(for commandID: String) -> Int
    func recordSuccessfulExecution(of commandID: String)
}

@MainActor
final class NoOpCommandPaletteUsageTracker: CommandPaletteUsageTracking {
    static let shared = NoOpCommandPaletteUsageTracker()

    private init() {}

    func useCount(for commandID: String) -> Int {
        _ = commandID
        return 0
    }

    func recordSuccessfulExecution(of commandID: String) {
        _ = commandID
    }
}

@MainActor
final class CommandPaletteUsageTracker: CommandPaletteUsageTracking {
    private static let usageFileName = "command-palette-usage.json"

    private let usageFileURL: URL
    private let fileManager: FileManager

    private var records: [String: CommandPaletteUsageRecord]

    init(
        runtimePaths: ToasttyRuntimePaths = .resolve(),
        fileManager: FileManager = .default
    ) {
        self.usageFileURL = runtimePaths.configDirectoryURL.appending(
            path: Self.usageFileName,
            directoryHint: .notDirectory
        )
        self.fileManager = fileManager
        self.records = Self.loadRecords(from: usageFileURL, fileManager: fileManager)
    }

    func useCount(for commandID: String) -> Int {
        records[commandID]?.count ?? 0
    }

    func recordSuccessfulExecution(of commandID: String) {
        let updatedRecord = CommandPaletteUsageRecord(
            count: (records[commandID]?.count ?? 0) + 1
        )
        records[commandID] = updatedRecord
        persistRecords()
    }

    private func persistRecords() {
        do {
            try fileManager.createDirectory(
                at: usageFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: usageFileURL, options: [.atomic])
        } catch {
            ToasttyLog.warning(
                "Failed to persist command palette usage",
                category: .state,
                metadata: [
                    "path": usageFileURL.path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private static func loadRecords(from usageFileURL: URL, fileManager: FileManager) -> [String: CommandPaletteUsageRecord] {
        guard fileManager.fileExists(atPath: usageFileURL.path) else {
            return [:]
        }

        do {
            let data = try Data(contentsOf: usageFileURL)
            return try JSONDecoder().decode([String: CommandPaletteUsageRecord].self, from: data)
        } catch {
            ToasttyLog.warning(
                "Failed to load command palette usage",
                category: .state,
                metadata: [
                    "path": usageFileURL.path,
                    "error": error.localizedDescription,
                ]
            )
            return [:]
        }
    }
}
