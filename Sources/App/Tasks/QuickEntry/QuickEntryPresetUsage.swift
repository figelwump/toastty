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

/// Counts the presets of the tasks created in quick entry, so the Agent
/// picker lists the user's favorites first and remembers the last used one.
/// Agent-created tasks do not count. Kept in
/// `~/.toastty/task-preset-usage.json`, as the command palette keeps its
/// usage. Also remembers the last workspace a quick entry task went to, in
/// `~/.toastty/task-last-workspace.json`.
@MainActor
final class QuickEntryPresetUsage {
    static let fileName = "task-preset-usage.json"
    static let lastWorkspaceFileName = "task-last-workspace.json"
    static let halfLife: TimeInterval = 14 * 24 * 60 * 60
    static let frequentLimit = 5

    private let fileURL: URL
    private let lastWorkspaceFileURL: URL
    private let fileManager: FileManager
    private let now: () -> Date
    /// Updated records move to the end. lastUsed uses this order to break
    /// timestamp ties, including dates rounded by ISO8601 persistence.
    private var records: [QuickEntryPresetUsageRecord]
    /// The workspace of the last task created in quick entry. It may have
    /// closed since.
    private(set) var lastWorkspaceID: UUID?

    init(
        runtimePaths: ToasttyRuntimePaths = .resolve(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        fileURL = runtimePaths.configDirectoryURL.appending(path: Self.fileName, directoryHint: .notDirectory)
        lastWorkspaceFileURL = runtimePaths.configDirectoryURL
            .appending(path: Self.lastWorkspaceFileName, directoryHint: .notDirectory)
        self.fileManager = fileManager
        self.now = now
        records = Self.load(from: fileURL, fileManager: fileManager)
        lastWorkspaceID = Self.loadLastWorkspace(from: lastWorkspaceFileURL, fileManager: fileManager)
    }

    private struct LastWorkspace: Codable {
        var workspaceID: UUID
    }

    func recordWorkspace(_ workspaceID: UUID) {
        guard workspaceID != lastWorkspaceID else { return }
        lastWorkspaceID = workspaceID
        write(LastWorkspace(workspaceID: workspaceID), to: lastWorkspaceFileURL, failure: "Failed to save the last quick entry workspace")
    }

    func record(_ preset: QuickEntryPreset) {
        let date = now()
        var record: QuickEntryPresetUsageRecord
        if let index = records.firstIndex(where: { $0.preset == preset }) {
            record = records.remove(at: index)
            record.score = Self.decayed(record, at: date) + 1
            record.count += 1
            record.lastUsedAt = date
        } else {
            record = QuickEntryPresetUsageRecord(preset: preset, count: 1, score: 1, lastUsedAt: date)
        }
        // Keep use order when ISO8601 persistence rounds two dates to the
        // same second. Ranking still uses the score, not array order.
        records.append(record)
        save()
    }

    /// The last successful choice, even when it is not a top-five favorite.
    func lastUsed(agents: Set<String>) -> QuickEntryPreset? {
        records.enumerated()
            .filter { agents.contains($0.element.preset.agent) }
            .max { lhs, rhs in
                if lhs.element.lastUsedAt != rhs.element.lastUsedAt {
                    return lhs.element.lastUsedAt < rhs.element.lastUsedAt
                }
                return lhs.offset < rhs.offset
            }?.element.preset
    }

    /// The top presets whose agent is still offered.
    func frequent(agents: Set<String>) -> [QuickEntryPreset] {
        Self.ranked(records, agents: agents, at: now())
    }

    /// Presets by recency-weighted count; a tie goes to the one used last,
    /// then to a fixed order. A preset
    /// whose agent profile is gone is left out.
    static func ranked(_ records: [QuickEntryPresetUsageRecord], agents: Set<String>, at date: Date) -> [QuickEntryPreset] {
        records
            .filter { agents.contains($0.preset.agent) }
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
        write(records, to: fileURL, failure: "Failed to save task preset usage")
    }

    private func write(_ value: some Encodable, to url: URL, failure: String) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: url, options: [.atomic])
        } catch {
            ToasttyLog.warning(failure, category: .tasks, metadata: [
                "path": url.path,
                "error": error.localizedDescription,
            ])
        }
    }

    private static func loadLastWorkspace(from url: URL, fileManager: FileManager) -> UUID? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(LastWorkspace.self, from: Data(contentsOf: url)).workspaceID
        } catch {
            ToasttyLog.warning("Failed to load the last quick entry workspace", category: .tasks, metadata: [
                "path": url.path,
                "error": error.localizedDescription,
            ])
            return nil
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
