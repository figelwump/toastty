import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct TaskInboxStoreTests {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "task-inbox-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "inbox.json")
    }

    @Test func savesEveryChangeAndReloadsIt() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TaskInboxStore(fileURL: url)
        let item = TaskInboxItem(
            text: "Fix the dot", attachments: [.init(displayName: "a.png", path: "/x/a.png")],
            source: .cli, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            pins: .init(profileID: "codex"), phase: .routing
        )
        store.add(item)
        store.update(id: item.id) {
            $0.phase = .setupFailed
            $0.problem = "The create script failed."
            $0.taskSpace = .init(workspaceID: UUID(), panelID: UUID())
        }
        let other = TaskInboxItem(text: "Second", source: .mac, createdAt: Date(timeIntervalSince1970: 1_800_000_100))
        store.add(other)
        store.remove(id: other.id)

        let reloaded = TaskInboxStore(fileURL: url)
        #expect(reloaded.items == store.items)
        #expect(reloaded.items.first?.problem == "The create script failed.")
    }

    @Test func unreadableFileIsMovedAsideAndTheInboxStartsEmpty() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)

        let store = TaskInboxStore(fileURL: url)
        #expect(store.items.isEmpty)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings.contains { $0.hasPrefix("inbox.json.corrupt-") })
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }
}
