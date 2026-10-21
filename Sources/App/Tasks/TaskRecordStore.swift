import CoreState
import Foundation

/// Every task record, saved to `task-records.json` in the runtime config
/// directory.
///
/// Adding, removing and `save` write the file before they return and throw
/// when the disk refuses, so after a crash the file names every task space
/// and agent that setup made. `update` saves after a short delay.
@MainActor
final class TaskRecordStore: ObservableObject {
    private static let currentSnapshotVersion = 1

    @Published private(set) var records: [TaskRecord]

    private let fileURL: URL?
    private let persistDebounceInterval: TimeInterval
    private let persistQueue = DispatchQueue(label: "toastty.task-records.persist")
    private var pendingPersistWorkItem: DispatchWorkItem?

    static func inMemory() -> TaskRecordStore {
        TaskRecordStore(fileURL: nil)
    }

    convenience init(runtimePaths: ToasttyRuntimePaths) {
        self.init(fileURL: runtimePaths.taskRecordsFileURL)
    }

    init(fileURL: URL?, persistDebounceInterval: TimeInterval = 0.25) {
        self.fileURL = fileURL
        self.persistDebounceInterval = persistDebounceInterval
        records = Self.loadRecords(from: fileURL)
    }

    func record(id: UUID) -> TaskRecord? {
        records.first { $0.id == id }
    }

    func record(clientRequestID: String, source: TaskSource) -> TaskRecord? {
        records.first { $0.clientRequestID == clientRequestID && $0.source == source }
    }

    func record(taskSpaceWorkspaceID workspaceID: UUID) -> TaskRecord? {
        records.first { $0.taskSpaceWorkspaceID == workspaceID }
    }

    /// Adds a record and saves at once. When the save fails, the record is
    /// not added and the error is thrown.
    func insert(_ record: TaskRecord) throws {
        guard self.record(id: record.id) == nil else { return }
        try commit(records + [record])
    }

    /// Changes one record and saves at once. Use it for a setup step that
    /// made, or is about to make, something outside the record. When the
    /// save fails, the change is dropped and the error is thrown.
    @discardableResult
    func save(id: UUID, _ body: (inout TaskRecord) -> Void) throws -> TaskRecord? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        var next = records
        body(&next[index])
        guard next[index] != records[index] else { return next[index] }
        try commit(next)
        return next[index]
    }

    /// Changes one record and saves after a short delay.
    @discardableResult
    func update(id: UUID, _ body: (inout TaskRecord) -> Void) -> TaskRecord? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        var record = records[index]
        body(&record)
        guard record != records[index] else { return record }
        records[index] = record
        schedulePersist()
        return record
    }

    /// Removes a record and saves at once. When the save fails, the record
    /// stays and the error is thrown.
    func remove(id: UUID) throws {
        guard records.contains(where: { $0.id == id }) else { return }
        try commit(records.filter { $0.id != id })
    }

    /// Writes every record now, including changes `update` left for a
    /// later write: before a step that must not run on unsaved state.
    func flush() throws {
        try commit(records)
    }

    func flushForTesting() {
        try? flush()
    }

    // MARK: - Persistence

    /// Writes `next` and only then publishes it, so memory never shows a
    /// state that the disk refused.
    private func commit(_ next: [TaskRecord]) throws {
        if let fileURL {
            pendingPersistWorkItem?.cancel()
            pendingPersistWorkItem = nil
            let data = try Self.encodeSnapshot(next)
            // The serial queue also finishes any earlier write first, so an
            // older snapshot can never land after this one.
            try persistQueue.sync {
                try Self.writeSnapshotData(data, to: fileURL)
            }
        }
        records = next
    }

    private func schedulePersist() {
        guard let fileURL else { return }
        pendingPersistWorkItem?.cancel()
        let data: Data
        do {
            data = try Self.encodeSnapshot(records)
        } catch {
            ToasttyLog.warning(
                "Failed encoding task records",
                category: .tasks,
                metadata: ["error": error.localizedDescription]
            )
            return
        }
        let workItem = Self.delayedWriteWorkItem(data, to: fileURL)
        pendingPersistWorkItem = workItem
        persistQueue.asyncAfter(deadline: .now() + persistDebounceInterval, execute: workItem)
    }

    /// Made outside the main actor: a closure formed in a main-actor method
    /// is main-actor isolated, and running it on the persist queue traps.
    private nonisolated static func delayedWriteWorkItem(_ data: Data, to fileURL: URL) -> DispatchWorkItem {
        DispatchWorkItem {
            do {
                try writeSnapshotData(data, to: fileURL)
            } catch {
                ToasttyLog.warning(
                    "Failed saving task records",
                    category: .tasks,
                    metadata: ["path": fileURL.path, "error": error.localizedDescription]
                )
            }
        }
    }

    private static func loadRecords(from fileURL: URL?) -> [TaskRecord] {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder.taskRecords.decode(TaskRecordsSnapshot.self, from: data)
            guard snapshot.version == currentSnapshotVersion else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Unsupported task records version: \(snapshot.version)"
                    )
                )
            }
            let records = snapshot.records.compactMap(\.record)
            if records.count < snapshot.records.count {
                let backupURL = backupFile(at: fileURL)
                ToasttyLog.warning(
                    "Dropped unreadable task records",
                    category: .tasks,
                    metadata: [
                        "dropped": String(snapshot.records.count - records.count),
                        "backup_path": backupURL?.path ?? "none",
                    ]
                )
            }
            return records
        } catch {
            let backupURL = backupFile(at: fileURL)
            ToasttyLog.warning(
                "Failed loading task records",
                category: .tasks,
                metadata: [
                    "path": fileURL.path,
                    "backup_path": backupURL?.path ?? "none",
                    "error": error.localizedDescription,
                ]
            )
            return []
        }
    }

    private static func encodeSnapshot(_ records: [TaskRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(
            EncodableTaskRecordsSnapshot(version: currentSnapshotVersion, records: records)
        )
    }

    private nonisolated static func writeSnapshotData(_ data: Data, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Copies the file aside before a later save replaces it, so records
    /// this version cannot read are not lost.
    private static func backupFile(at fileURL: URL) -> URL? {
        let backupURL = fileURL.deletingLastPathComponent().appending(
            path: "\(fileURL.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)",
            directoryHint: .notDirectory
        )
        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            return backupURL
        } catch {
            ToasttyLog.warning(
                "Failed backing up task records file",
                category: .tasks,
                metadata: ["path": fileURL.path, "error": error.localizedDescription]
            )
            return nil
        }
    }
}

private extension JSONDecoder {
    static var taskRecords: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct EncodableTaskRecordsSnapshot: Encodable {
    var version: Int
    var records: [TaskRecord]
}

/// Decodes each record on its own, so one unreadable record does not drop
/// the others.
private struct TaskRecordsSnapshot: Decodable {
    struct LossyRecord: Decodable {
        let record: TaskRecord?

        init(from decoder: any Decoder) throws {
            record = try? TaskRecord(from: decoder)
        }
    }

    var version: Int
    var records: [LossyRecord]
}
