import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct TaskRecordStoreTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-task-records-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(_ title: String) -> TaskRecord {
        TaskRecord(createdAt: Date(timeIntervalSince1970: 1_000), text: title, title: title, slug: title, source: .cli)
    }

    @Test func durableChangesAreOnDiskBeforeTheCallReturns() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("task-records.json")
        // A long delay, so only a durable write can reach the disk in time.
        let store = TaskRecordStore(fileURL: fileURL, persistDebounceInterval: 60)
        let first = record("first")
        try store.insert(first)
        #expect(TaskRecordStore(fileURL: fileURL).record(id: first.id) == first)

        store.update(id: first.id) { $0.title = "renamed later" }
        #expect(TaskRecordStore(fileURL: fileURL).record(id: first.id)?.title == "first")

        try store.save(id: first.id) { $0.setup = .started }
        let reloaded = TaskRecordStore(fileURL: fileURL).record(id: first.id)
        #expect(reloaded?.setup == .started)
        #expect(reloaded?.title == "renamed later")

        try store.remove(id: first.id)
        #expect(TaskRecordStore(fileURL: fileURL).records.isEmpty)
    }

    @Test func aRefusedSaveLeavesMemoryAsTheDiskHasIt() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let store = TaskRecordStore(fileURL: blocker.appendingPathComponent("task-records.json"))
        #expect(throws: (any Error).self) { try store.insert(record("lost")) }
        #expect(store.records.isEmpty)
    }

    @Test func anUnreadableFileIsKeptAsideAndLoadsEmpty() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("task-records.json")
        try Data("{ not json".utf8).write(to: fileURL)

        let store = TaskRecordStore(fileURL: fileURL)
        #expect(store.records.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("task-records.json.corrupt-") }
        #expect(backups.count == 1)
    }

    @Test func oneUnreadableRecordDoesNotDropTheOthers() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("task-records.json")
        let store = TaskRecordStore(fileURL: fileURL)
        let kept = record("kept")
        try store.insert(kept)

        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var records = try #require(object["records"] as? [Any])
        records.append(["id": "not-a-uuid"])
        object["records"] = records
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)

        let reloaded = TaskRecordStore(fileURL: fileURL)
        #expect(reloaded.records == [kept])
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("task-records.json.corrupt-") }
        #expect(backups.count == 1)
    }

    @Test func runtimePathsKeepRecordsInTheRuntimeHome() throws {
        let home = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = ToasttyRuntimePaths.resolve(environment: ["TOASTTY_RUNTIME_HOME": home.path])
        #expect(paths.taskRecordsFileURL.path.hasPrefix(home.path))
        #expect(paths.taskAttachmentsDirectoryURL.path.hasPrefix(home.path))
    }
}
