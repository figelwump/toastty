import CoreState
import Foundation
import Testing

struct TaskRecordTests {
    @Test
    func defaultTitleIsTheFirstNonEmptyLine() {
        #expect(TaskRecord.defaultTitle(for: "\n  Fix the unread dot  \nmore detail") == "Fix the unread dot")
        #expect(TaskRecord.defaultTitle(for: " \n\t\n") == nil)
        let long = String(repeating: "word ", count: 40)
        let title = TaskRecord.defaultTitle(for: long)
        #expect(title?.count ?? 0 <= TaskRecord.maximumTitleLength)
        #expect(title?.hasSuffix("…") == true)
    }

    @Test
    func slugsAreLowercaseWordsWithinTheLimit() {
        #expect(TaskRecord.sanitizedSlug("Billing page shows the OLD plan!") == "billing-page-shows-the-old-plan")
        #expect(TaskRecord.sanitizedSlug("日本語 only") == "only")
        #expect(TaskRecord.sanitizedSlug("!!!") == nil)
        let slug = TaskRecord.sanitizedSlug(String(repeating: "abcdefgh ", count: 10))
        #expect((slug?.count ?? 0) <= TaskRecord.maximumSlugLength)
        #expect(slug?.hasSuffix("-") == false)
    }

    @Test
    func uniqueSlugAddsANumber() {
        #expect(TaskRecord.uniqueSlug("fix-dot", taken: []) == "fix-dot")
        #expect(TaskRecord.uniqueSlug("fix-dot", taken: ["fix-dot", "fix-dot-2"]) == "fix-dot-3")
        let full = String(repeating: "a", count: 19) + "-" + String(repeating: "b", count: 20)
        let unique = TaskRecord.uniqueSlug(full, taken: [full])
        #expect(unique.count <= TaskRecord.maximumSlugLength)
        #expect(unique.contains("--") == false)
    }

    @Test
    func promptKeepsTextAndFilesAfterTheFirstPrompt() {
        let prompt = TaskPrompt.compose(
            firstPrompt: "Fix it. Start work at once.",
            text: "Composer keeps a blank line",
            attachmentPaths: ["/tmp/a.png", "/tmp/b c.pdf"]
        )
        #expect(prompt == """
        Fix it. Start work at once.

        The task, as written:

        Composer keeps a blank line

        Attached files:
        - /tmp/a.png
        - /tmp/b c.pdf
        """)
    }

    @Test
    func promptWithoutFirstPromptIsTheTextAlone() {
        // The text keeps its own spacing, such as indented code.
        #expect(TaskPrompt.compose(firstPrompt: nil, text: "    let x = 1\n", attachmentPaths: []) == "    let x = 1\n")
        #expect(TaskPrompt.compose(firstPrompt: "Same", text: "Same", attachmentPaths: []) == "Same")
    }

    @Test
    func recordRoundTripsThroughJSON() throws {
        let record = TaskRecord(
            clientRequestID: "req-1",
            createdAt: Date(timeIntervalSince1970: 1_000),
            text: "Fix it",
            attachments: [TaskAttachment(path: "/a/b.png", displayName: "b.png")],
            title: "Fix it",
            slug: "fix-it",
            source: .agent(sessionID: "s1"),
            pinned: TaskFields(agent: "codex"),
            resolved: TaskFields(agent: "codex", model: "gpt-6.1-sol", effort: "high"),
            workspaceID: UUID(),
            projectRoot: "/repo",
            setup: .setupFailed(reason: "boom"),
            operation: TaskOperation(
                taskSpace: .init(workspaceID: UUID(), panelID: UUID()),
                agentLaunch: .init(sessionID: "s2", at: Date(timeIntervalSince1970: 2_000))
            )
        )
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(TaskRecord.self, from: data) == record)
        #expect(record.taskSpaceWorkspaceID == record.operation.taskSpace?.workspaceID)
    }

    @Test(arguments: [TaskSource.cli, .agent(sessionID: "s1"), .quickEntry, .recovered])
    func sourceRoundTripsThroughJSON(source: TaskSource) throws {
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(TaskSource.self, from: data) == source)
    }

    @Test
    func moveIntoAWorktreeRoundTripsAndOlderRecordsStillRead() throws {
        var record = TaskRecord(
            createdAt: Date(timeIntervalSince1970: 1_000),
            text: "Fix it",
            title: "Fix it",
            slug: "fix-it",
            source: .cli,
            setup: .started,
            parentTaskID: UUID(),
            startWork: TaskStartWork(
                branchPrefix: "fix",
                base: "main",
                source: .init(sessionID: "s1", panelID: UUID(), agent: "claude"),
                requestedAt: Date(timeIntervalSince1970: 1_500),
                state: .failed(reason: "hook failed")
            )
        )
        record.operation.base = .init(sha: "abc", ref: "origin/main", fetched: false, note: "offline")
        record.operation.worktree = .init(path: "/w", branch: "fix/fix-it", checkoutRoot: "/repo", added: false)
        record.operation.worktreeSession = .init(workspaceID: UUID(), panelID: UUID(), sessionID: "s2", forked: true)
        record.operation.sourceOutcome = .kept(reason: "typed")
        #expect(try JSONDecoder().decode(TaskRecord.self, from: JSONEncoder().encode(record)) == record)
        // Reserved but not added yet: not the task's worktree.
        #expect(record.worktree == nil)
        #expect(record.currentSessionID == "s2")

        // A record saved before tasks could move has none of these fields.
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(TaskRecord(
            createdAt: Date(), text: "a", title: "a", slug: "a", source: .cli
        ))) as? [String: Any])
        old.removeValue(forKey: "startWork")
        old.removeValue(forKey: "parentTaskID")
        old["operation"] = [String: Any]()
        let decoded = try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.startWork == nil)
        #expect(decoded.operation == TaskOperation())
    }

    @Test
    func branchPrefixIsLowercaseWordsJoinedBySlashes() {
        for valid in ["fix", "feat", "user/vishal", "release-2"] {
            #expect(TaskStartWork.isValidBranchPrefix(valid), "\(valid)")
        }
        for invalid in ["", "Fix", "fix/", "/fix", "fix//x", "fix it", "-fix", "fix..x", String(repeating: "a", count: 41)] {
            #expect(TaskStartWork.isValidBranchPrefix(invalid) == false, "\(invalid)")
        }
    }
}
