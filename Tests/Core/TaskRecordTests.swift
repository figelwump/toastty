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

        \(TaskPrompt.replyLine)
        """)
    }

    @Test
    func promptWithoutFirstPromptIsTheTextAlone() {
        // The text keeps its own spacing, such as indented code.
        #expect(TaskPrompt.compose(firstPrompt: nil, text: "    let x = 1\n", attachmentPaths: [])
            == "    let x = 1\n\n\n\(TaskPrompt.replyLine)")
        #expect(TaskPrompt.compose(firstPrompt: "Same", text: "Same", attachmentPaths: []) == "Same\n\n\(TaskPrompt.replyLine)")
    }

    @Test
    func startSkillLineComesFirst() {
        let worktree = TaskOperation.Worktree(path: "/w/fix", branch: "fix/composer", checkoutRoot: "/r", added: true)
        #expect(TaskPrompt.compose(skill: "task-start", firstPrompt: nil, text: "Fix it", attachmentPaths: []) == """
        Use the task-start skill.

        Fix it

        \(TaskPrompt.replyLine)
        """)
        // Before the worktree line and a first prompt that triage or the
        // caller wrote.
        #expect(TaskPrompt.compose(
            skill: "task-start",
            firstPrompt: "Start with the views.",
            text: "Fix it",
            attachmentPaths: [],
            worktree: worktree
        ) == """
        Use the task-start skill.

        You are in the git worktree /w/fix, on branch fix/composer.

        Start with the views.

        The task, as written:

        Fix it

        \(TaskPrompt.replyLine)
        """)
    }

    @Test
    func onlyAFreshMovedSessionGetsTheStartSkillAgain() {
        let worktree = TaskOperation.Worktree(path: "/w/fix", branch: "fix/composer", checkoutRoot: "/r", added: true)
        let record = TaskRecord(
            createdAt: Date(),
            text: "Fix it",
            title: "Fix it",
            slug: "fix-it",
            source: .cli,
            resolved: TaskFields(agent: "cursor", skill: "task-start")
        )
        let fresh = TaskPrompt.movedToWorktree(record: record, worktree: worktree, base: nil, forked: false)
        #expect(fresh.hasPrefix("Use the task-start skill.\n\nYou are in the git worktree /w/fix"))
        #expect(fresh.hasSuffix("cannot continue.\n\nFix it\n\n\(TaskPrompt.replyLine)"))
        let forked = TaskPrompt.movedToWorktree(record: record, worktree: worktree, base: nil, forked: true)
        #expect(forked.contains("skill") == false)
    }

    @Test(arguments: [
        (nil, nil, "Use the toastty-task-merge skill.\n\nThe user accepted URL for merging."),
        ("my-merge", nil, "Use the my-merge skill.\n\nThe user accepted URL for merging."),
        (nil, "Use worktree-done.", "Use worktree-done.\n\nThe user accepted URL for merging."),
        ("my-merge", "Wait for CI.", "Use the my-merge skill.\n\nWait for CI.\n\nThe user accepted URL for merging."),
    ] as [(String?, String?, String)])
    func mergeMessageForEachSetting(skill: String?, prompt: String?, expected: String) {
        #expect(TaskPrompt.merge(skill: skill, prompt: prompt, pullRequestURL: "URL") == expected)
    }

    @Test
    func recordRoundTripsThroughJSON() throws {
        var record = TaskRecord(
            clientRequestID: "req-1",
            createdAt: Date(timeIntervalSince1970: 1_000),
            text: "Fix it",
            attachments: [TaskAttachment(path: "/a/b.png", displayName: "b.png")],
            title: "Fix it",
            slug: "fix-it",
            source: .agent(sessionID: "s1"),
            pinned: TaskFields(agent: "codex", skill: "toastty-release"),
            resolved: TaskFields(agent: "codex", model: "gpt-6.1-sol", effort: "high", skill: "task-start"),
            workspaceID: UUID(),
            projectRoot: "/repo",
            setup: .setupFailed(reason: "boom"),
            operation: TaskOperation(
                taskSpace: .init(workspaceID: UUID(), panelID: UUID()),
                agentLaunch: .init(sessionID: "s2", at: Date(timeIntervalSince1970: 2_000))
            )
        )
        // A record without a reply request, as saved before it existed,
        // leaves the key out.
        #expect(String(decoding: try JSONEncoder().encode(record), as: UTF8.self).contains("replyRequest") == false)
        record.replyRequest = TaskReplyRequest(askedAt: Date(timeIntervalSince1970: 3_000), question: "Which option?")
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
