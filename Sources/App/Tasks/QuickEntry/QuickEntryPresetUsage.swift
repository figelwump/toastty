import CoreState
import Foundation

/// How often one agent preset was chosen at Create Task.
struct QuickEntryPresetUsageRecord: Codable, Equatable, Sendable {
    var preset: QuickEntryPreset
    var count: Int
    /// The recency-weighted count as of `lastUsedAt`: each use adds 1, and
    /// the total halves every `QuickEntryPresetUsage.halfLife`.
    var score: Double
    var lastUsedAt: Date
}

/// Counts the presets the user picks in quick entry, so the Agent picker
/// lists their favorites first. Only explicit choices are recorded: Auto,
/// triage and agent-created tasks do not count. Kept in
/// `~/.toastty/task-preset-usage.json`, as the command palette keeps its
/// usage.
@MainActor
final class QuickEntryPresetUsage {
    static let fileName = "task-preset-usage.json"
    static let halfLife: TimeInterval = 14 * 24 * 60 * 60
    /// A preset is listed once it has been used this many times.
    static let minimumUses = 2
    static let frequentLimit = 5

    private let fileURL: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private var records: [QuickEntryPresetUsageRecord]

    init(
        runtimePaths: ToasttyRuntimePaths = .resolve(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        fileURL = runtimePaths.configDirectoryURL.appending(path: Self.fileName, directoryHint: .notDirectory)
        self.fileManager = fileManager
        self.now = now
        records = Self.load(from: fileURL, fileManager: fileManager)
    }

    func record(_ preset: QuickEntryPreset) {
        let date = now()
        if let index = records.firstIndex(where: { $0.preset == preset }) {
            records[index].score = Self.decayed(records[index], at: date) + 1
            records[index].count += 1
            records[index].lastUsedAt = date
        } else {
            records.append(QuickEntryPresetUsageRecord(preset: preset, count: 1, score: 1, lastUsedAt: date))
        }
        save()
    }

    /// The top presets whose agent is still offered.
    func frequent(agents: Set<String>) -> [QuickEntryPreset] {
        Self.ranked(records, agents: agents, at: now())
    }

    /// Presets used at least `minimumUses` times, by recency-weighted count;
    /// a tie goes to the one used last, then to a fixed order. A preset
    /// whose agent profile is gone is left out.
    static func ranked(_ records: [QuickEntryPresetUsageRecord], agents: Set<String>, at date: Date) -> [QuickEntryPreset] {
        records
            .filter { $0.count >= minimumUses && agents.contains($0.preset.agent) }
            .map { (record: $0, score: decayed($0, at: date)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.record.lastUsedAt != rhs.record.lastUsedAt { return lhs.record.lastUsedAt > rhs.record.lastUsedAt }
                return QuickEntryPicker.presetRowID(lhs.record.preset) < QuickEntryPicker.presetRowID(rhs.record.preset)
            }
            .prefix(frequentLimit)
            .map(\.record.preset)
    }

    static func decayed(_ record: QuickEntryPresetUsageRecord, at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(record.lastUsedAt))
        return record.score * pow(0.5, elapsed / halfLife)
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: fileURL, options: [.atomic])
        } catch {
            ToasttyLog.warning("Failed to save task preset usage", category: .tasks, metadata: [
                "path": fileURL.path,
                "error": error.localizedDescription,
            ])
        }
    }

    private static func load(from fileURL: URL, fileManager: FileManager) -> [QuickEntryPresetUsageRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([QuickEntryPresetUsageRecord].self, from: Data(contentsOf: fileURL))
        } catch {
            ToasttyLog.warning("Failed to load task preset usage", category: .tasks, metadata: [
                "path": fileURL.path,
                "error": error.localizedDescription,
            ])
            return []
        }
    }
}
