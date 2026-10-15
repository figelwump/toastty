import CoreState
import Foundation
import RemoteProtocol
import Testing

struct TaskSpaceCreationTests {
    // Failure modes: selecting the new task space, nesting it more than one
    // level deep, starting its terminal elsewhere or with a profile, and
    // reusing an ID that already exists.
    @Test func createsAnUnvisitedTaskSpaceWithItsTerminalInTheDirectory() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "default")
        let windowID = try #require(state.windows.first?.id)
        let parentID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceID = UUID()
        let panelID = UUID()

        #expect(AppReducer.reduce(action: .createTaskSpace(
            windowID: windowID, workspaceID: workspaceID, panelID: panelID,
            parentWorkspaceID: parentID, title: "ios-unread-dot", terminalCWD: "/tmp/task-dir"
        ), state: &state))

        let taskSpace = try #require(state.workspacesByID[workspaceID])
        #expect(taskSpace.title == "ios-unread-dot")
        #expect(taskSpace.parentWorkspaceID == parentID)
        #expect(taskSpace.hasBeenVisited == false)
        #expect(state.windows.first?.selectedWorkspaceID == parentID)
        #expect(state.windows.first?.workspaceIDs.last == workspaceID)
        guard case .terminal(let terminal)? = taskSpace.panelState(for: panelID) else {
            Issue.record("Expected the caller's terminal ID")
            return
        }
        #expect(terminal.cwd == "/tmp/task-dir")
        #expect(terminal.profileBinding == nil)

        // A task space under a task space nests under the root instead.
        let nestedID = UUID()
        #expect(AppReducer.reduce(action: .createTaskSpace(
            windowID: windowID, workspaceID: nestedID, panelID: UUID(),
            parentWorkspaceID: workspaceID, title: "nested", terminalCWD: "/tmp"
        ), state: &state))
        #expect(state.workspacesByID[nestedID]?.parentWorkspaceID == parentID)

        // Reused IDs and unknown parents change nothing.
        let before = state
        #expect(AppReducer.reduce(action: .createTaskSpace(
            windowID: windowID, workspaceID: workspaceID, panelID: UUID(),
            parentWorkspaceID: parentID, title: "again", terminalCWD: "/tmp"
        ), state: &state) == false)
        #expect(AppReducer.reduce(action: .createTaskSpace(
            windowID: windowID, workspaceID: UUID(), panelID: panelID,
            parentWorkspaceID: parentID, title: "again", terminalCWD: "/tmp"
        ), state: &state) == false)
        #expect(AppReducer.reduce(action: .createTaskSpace(
            windowID: windowID, workspaceID: UUID(), panelID: UUID(),
            parentWorkspaceID: UUID(), title: "again", terminalCWD: "/tmp"
        ), state: &state) == false)
        #expect(state == before)
    }
}

struct TaskAttachmentRetentionTests {
    private func makeStore() throws -> (RemoteMessageAttachmentStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "task-attachments-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "attachments", directoryHint: .isDirectory)
        return (RemoteMessageAttachmentStore(root: root), root)
    }

    private let file = RemoteMessageAttachment(filename: "notes.txt", data: Data("repro steps".utf8))

    @Test func protectedDirectoriesOutliveRetentionAndRenewRestartsIt() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let staged = Date(timeIntervalSince1970: 1_800_000_000)
        let waiting = try await store.stage([file], at: staged)
        let started = try await store.stage([file], at: staged)
        let old = staged.addingTimeInterval(-1)
        for directory in [waiting.directory, started.directory] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: directory.path)
        }

        // Eight days later the task still waiting in the Inbox keeps its
        // files; the started one was renewed at delivery and keeps them too.
        let delivered = staged.addingTimeInterval(7 * 24 * 3600 - 60)
        await store.renew(directory: started.directory, at: delivered)
        let eightDaysLater = staged.addingTimeInterval(8 * 24 * 3600)
        try await store.cleanup(at: eightDaysLater, protecting: [waiting.directory.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: waiting.files[0].path))
        #expect(FileManager.default.fileExists(atPath: started.files[0].path))

        // Without protection or renewal, the sweep removes them.
        try await store.cleanup(at: delivered.addingTimeInterval(8 * 24 * 3600))
        #expect(FileManager.default.fileExists(atPath: waiting.directory.path) == false)
        #expect(FileManager.default.fileExists(atPath: started.directory.path) == false)
    }

    @Test func discardRemovesOnlyItsOwnDirectories() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let staged = try await store.stage([file])
        let outside = root.deletingLastPathComponent().appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        await store.discard(directory: outside)
        await store.discard(directory: staged.directory)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: staged.directory.path) == false)
    }
}
