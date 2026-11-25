import CoreState
import Foundation
import Testing
@testable import ToasttyAppLogic

/// Continue as New Task opens quick entry with the earlier task's context
/// attached as a Markdown file; the text stays what the user types.
@MainActor
@Suite(.serialized)
struct QuickEntryContinuationTests {
    @Test func theContextIsAttachedOnceAndCanBeRemoved() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let continuation = QuickEntryContinuation(
            taskID: UUID(), taskTitle: "Clamp the jig", fileName: "continues-clamp-the-jig.md", text: "# Continues\n"
        )
        let model = QuickEntryModel(
            prefill: QuickEntryPrefill(continuation: continuation),
            workspaceOptions: [],
            agentProfiles: [],
            frequentPresets: [],
            stagingDirectoryURL: staging,
            create: { _ in throw TaskError("not in this test") },
            onCreated: { _ in },
            onCancel: {}
        )
        defer { model.removeStagingDirectoryNow() }

        #expect(model.text.isEmpty)
        #expect(model.attachments.map(\.displayName) == ["continues-clamp-the-jig.md"])
        #expect(model.continuesTaskTitle == "Clamp the jig")
        let url = try #require(model.attachments.first?.url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Continues\n")

        // The same task again, while the panel is open, does not attach twice.
        model.apply(QuickEntryPrefill(continuation: continuation))
        #expect(model.attachments.count == 1)

        // Removing the file ends the continuation; asking again attaches it again.
        model.removeAttachment(id: try #require(model.attachments.first?.id))
        #expect(model.continuesTaskTitle == nil)
        model.apply(QuickEntryPrefill(continuation: continuation))
        #expect(model.continuesTaskTitle == "Clamp the jig")

        // Another task's continuation replaces the first.
        let other = QuickEntryContinuation(taskID: UUID(), taskTitle: "Plan welds", fileName: "continues-plan-welds.md", text: "x")
        model.apply(QuickEntryPrefill(continuation: other))
        #expect(model.attachments.map(\.displayName) == ["continues-plan-welds.md"])
        #expect(model.continuesTaskTitle == "Plan welds")
    }
}
