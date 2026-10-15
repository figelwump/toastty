import CoreState
import Foundation
import RemoteProtocol
import Testing

struct TaskPlacementTests {
    private let toasttyID = UUID()
    private let websiteID = UUID()
    private let noDirectoryID = UUID()
    private let taskSpaceID = UUID()

    private var context: TaskPlacementContext {
        TaskPlacementContext(
            workspaces: [
                .init(id: toasttyID, title: "toastty", directory: "/repos/toastty", isTopLevel: true, taskSpaceTitles: ["ios-unread-dot"]),
                .init(id: websiteID, title: "website", directory: "/repos/website", isTopLevel: true),
                .init(id: noDirectoryID, title: "scratch", directory: nil, isTopLevel: true),
                .init(id: taskSpaceID, title: "scroll-jank", directory: nil, isTopLevel: false),
            ],
            profiles: [
                .init(id: "claude", displayName: "Claude Code", agent: .claude, isAvailable: true, supportsModel: true, efforts: ["low", "high", "xhigh"]),
                .init(id: "codex", displayName: "Codex", agent: .codex, isAvailable: true, supportsModel: true, efforts: ["low", "high"]),
                .init(id: "cursor", displayName: "Cursor", agent: .cursor, isAvailable: true, supportsModel: false, efforts: []),
                .init(id: "pi", displayName: "Pi", agent: .pi, isAvailable: false, supportsModel: true, efforts: []),
            ],
            reservedSlugs: [toasttyID: ["fix-sidebar"]]
        )
    }

    private func answer(
        workspaceID: String,
        slug: String = "fix-sidebar-dot",
        profileID: String = "claude",
        model: String? = "claude-opus-5-5",
        effort: String? = "xhigh"
    ) -> TaskTriageAnswer {
        TaskTriageAnswer(
            workspaceID: workspaceID, title: "Fix the sidebar dot", slug: slug, branchPrefix: "fix",
            profileID: profileID, model: model, effort: effort, confident: true, reason: "Sidebar bug."
        )
    }

    @Test(arguments: [
        ("Fix the iOS unread dot!", "fix-the-ios-unread-dot"),
        ("  --Résumé   upload ", "r-sum-upload"),
        ("一二三", nil),
        ("aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd eeee", "aaaaaaaaaa-bbbbbbbbbb-cccccccccc"),
    ] as [(String, String?)])
    func slugsAreLowercaseWordsWithinTheLimit(raw: String, expected: String?) {
        #expect(TaskPlacement.sanitizedSlug(raw) == expected)
    }

    @Test func uniqueSlugAddsTheFirstFreeNumber() {
        #expect(TaskPlacement.uniqueSlug("fix", taken: []) == "fix")
        #expect(TaskPlacement.uniqueSlug("fix", taken: ["fix", "fix-2"]) == "fix-3")
    }

    @Test func suggestionKeepsValidFieldsAndDropsOnesThatFailChecks() {
        let valid = TaskPlacement.suggestion(from: answer(workspaceID: toasttyID.uuidString), context: context)
        #expect(valid == .init(
            workspaceID: toasttyID, title: "Fix the sidebar dot", slug: "fix-sidebar-dot", branchPrefix: "fix",
            profileID: "claude", model: "claude-opus-5-5", effort: "xhigh", reason: "Sidebar bug."
        ))

        // A task space, a workspace with no directory, an unknown ID, an
        // unavailable agent, an effort the agent lacks, an unsafe model.
        for workspaceID in [taskSpaceID.uuidString, noDirectoryID.uuidString, "not-a-uuid"] {
            #expect(TaskPlacement.suggestion(from: answer(workspaceID: workspaceID), context: context).workspaceID == nil)
        }
        let unavailable = TaskPlacement.suggestion(from: answer(workspaceID: toasttyID.uuidString, profileID: "pi"), context: context)
        #expect(unavailable.profileID == nil)
        #expect(unavailable.model == nil)
        let badEffort = TaskPlacement.suggestion(from: answer(workspaceID: toasttyID.uuidString, profileID: "codex", effort: "xhigh"), context: context)
        #expect(badEffort.effort == nil)
        let badModel = TaskPlacement.suggestion(from: answer(workspaceID: toasttyID.uuidString, model: "--dangerously"), context: context)
        #expect(badModel.model == nil)
        let noModelAgent = TaskPlacement.suggestion(from: answer(workspaceID: toasttyID.uuidString, profileID: "cursor"), context: context)
        #expect(noModelAgent.model == nil)
    }

    @Test func planUsesTheSuggestionAndReservesAFreeSlug() throws {
        var item = TaskInboxItem(text: "the dot", source: .cli, createdAt: .distantPast)
        item.suggestion = TaskPlacement.suggestion(
            from: answer(workspaceID: toasttyID.uuidString, slug: "fix-sidebar"),
            context: context
        )
        let plan = try TaskPlacement.plan(for: item, context: context).get()
        #expect(plan == .init(
            workspaceID: toasttyID, title: "Fix the sidebar dot", slug: "fix-sidebar-2", branchPrefix: "fix",
            profileID: "claude", model: "claude-opus-5-5", effort: "xhigh"
        ))
        // An existing task space's title is taken too.
        item.suggestion?.slug = "ios-unread-dot"
        #expect(try TaskPlacement.plan(for: item, context: context).get().slug == "ios-unread-dot-2")
    }

    @Test func pinsWinAndAreCheckedAgainstTheChosenAgent() throws {
        var item = TaskInboxItem(text: "Update the pricing table", source: .cli, createdAt: .distantPast)
        item.suggestion = TaskPlacement.suggestion(from: answer(workspaceID: toasttyID.uuidString), context: context)

        // A pinned agent drops the suggestion's model and effort, which were
        // picked for another agent.
        item.pins = .init(workspaceID: websiteID, profileID: "codex")
        let plan = try TaskPlacement.plan(for: item, context: context).get()
        #expect(plan.workspaceID == websiteID)
        #expect(plan.profileID == "codex")
        #expect(plan.model == nil)
        #expect(plan.effort == nil)

        item.pins = .init(profileID: "codex", effort: "xhigh")
        #expect(TaskPlacement.plan(for: item, context: context) == .failure(.effortNotSupported(effort: "xhigh", agent: "Codex")))
        item.pins = .init(profileID: "cursor", model: "gpt")
        #expect(TaskPlacement.plan(for: item, context: context) == .failure(.modelNotSupported(agent: "Cursor")))
        item.pins = .init(profileID: "pi")
        #expect(TaskPlacement.plan(for: item, context: context) == .failure(.agentUnavailable(profileID: "pi")))
    }

    @Test func planNamesWhyAWorkspaceCannotBeUsed() {
        let item = TaskInboxItem(text: "x", source: .cli, createdAt: .distantPast)
        #expect(TaskPlacement.plan(for: item, context: context) == .failure(.noWorkspace))
        #expect(TaskPlacement.plan(for: item, workspaceID: UUID(), context: context) == .failure(.workspaceClosed))
        #expect(TaskPlacement.plan(for: item, workspaceID: taskSpaceID, context: context) == .failure(.workspaceIsTaskSpace(title: "scroll-jank")))
        #expect(TaskPlacement.plan(for: item, workspaceID: noDirectoryID, context: context) == .failure(.workspaceHasNoDirectory(title: "scratch")))
    }

    @Test func planWithoutTriageUsesTheFirstLineAndTheFirstAvailableAgent() throws {
        let item = TaskInboxItem(text: "\n  Make the iOS composer keep drafts\nmore detail", source: .cli, createdAt: .distantPast)
        let plan = try TaskPlacement.plan(for: item, workspaceID: websiteID, context: context).get()
        #expect(plan.title == "Make the iOS composer keep drafts")
        #expect(plan.slug == "make-the-ios-composer-keep-drafts")
        #expect(plan.branchPrefix == "feat")
        #expect(plan.profileID == "claude")
    }

    @Test func defaultTitleShortensLongFirstLines() {
        let title = TaskInboxItem.defaultTitle(for: String(repeating: "word ", count: 30))
        #expect(title.count == TaskInboxItem.maximumTitleLength)
        #expect(title.hasSuffix("…"))
        #expect(TaskInboxItem.defaultTitle(for: "   \n ") == "Untitled task")
    }
}

struct TaskTriageTests {
    @Test func promptListsOnlyPlaceableWorkspacesAndAvailableAgents() throws {
        let toastty = UUID()
        let context = TaskPlacementContext(
            workspaces: [
                .init(id: toastty, title: "toastty", directory: "/repos/toastty", isTopLevel: true, taskSpaceTitles: (1...7).map { "t\($0)" }),
                .init(id: UUID(), title: "no-dir", directory: nil, isTopLevel: true),
            ],
            profiles: [
                .init(id: "claude", displayName: "Claude Code", agent: .claude, isAvailable: true, supportsModel: true, efforts: ["high"]),
                .init(id: "pi", displayName: "Pi", agent: .pi, isAvailable: false, supportsModel: true, efforts: []),
            ]
        )
        let item = TaskInboxItem(
            text: "Fix it", attachments: [.init(displayName: "shot.png", path: "/x/1.png")],
            source: .mac, createdAt: .distantPast, pins: .init(profileID: "claude")
        )
        let prompt = try TaskTriage.prompt(for: item, context: context, guidance: "Prefer claude.")
        let json = try #require(prompt.components(separatedBy: "INPUT:\n").last)
        let input = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        let workspaces = try #require(input["workspaces"] as? [[String: Any]])
        #expect(workspaces.map { $0["title"] as? String } == ["toastty"])
        #expect(workspaces.first?["recentTaskSpaces"] as? [String] == ["t3", "t4", "t5", "t6", "t7"])
        #expect((input["agents"] as? [[String: Any]])?.map { $0["profileID"] as? String } == ["claude"])
        #expect((input["task"] as? [String: Any])?["files"] as? [String] == ["shot.png"])
        #expect((input["fixed"] as? [String: Any])?["profileID"] as? String == "claude")
        #expect(input["guidance"] as? String == "Prefer claude.")
        #expect(prompt.hasPrefix(TaskTriage.instructions))
    }

    @Test func outputSchemaIsValidJSONThatRequiresEveryField() throws {
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(TaskTriage.outputSchemaJSON.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(schema["required"] as? [String] ?? []) == Set(properties.keys))
        #expect(schema["additionalProperties"] as? Bool == false)
    }

    @Test func readsClaudeResultsAndErrors() throws {
        let success = Data(#"{"type":"result","subtype":"success","is_error":false,"structured_output":{"workspaceID":"W","title":"T","slug":"s","branchPrefix":"fix","profileID":"claude","model":null,"effort":"low","confident":true,"reason":"r"}}"#.utf8)
        let answer = try TaskTriage.answer(fromClaudeOutput: success)
        #expect(answer.workspaceID == "W")
        #expect(answer.model == nil)
        #expect(answer.effort == "low")

        let failure = Data(#"{"type":"result","subtype":"error","is_error":true,"result":"Not logged in · Please run /login\nmore"}"#.utf8)
        #expect(throws: TaskTriageOutputError.providerError("Not logged in · Please run /login")) {
            try TaskTriage.answer(fromClaudeOutput: failure)
        }
        #expect(throws: TaskTriageOutputError.unreadable) {
            try TaskTriage.answer(fromClaudeOutput: Data("not json".utf8))
        }
    }

    @Test func readsTheCodexLastMessage() throws {
        let message = Data(#"{"workspaceID":"W","title":"T","slug":"s","branchPrefix":"feat","profileID":"codex","model":"gpt-6.1-sol","effort":null,"confident":false,"reason":"r"}"#.utf8)
        #expect(try TaskTriage.answer(fromCodexLastMessage: message).confident == false)
        #expect(throws: TaskTriageOutputError.unreadable) {
            try TaskTriage.answer(fromCodexLastMessage: Data(#"{"slug":"s"}"#.utf8))
        }
    }
}

struct TaskSetupTests {
    @Test func createOutputIsTheLastJSONLine() throws {
        let stdout = """
        Preparing worktree (new branch 'fix/x')
        {"directory": "~/repos/toastty-x", "branch": "fix/x", "baseRef": "abc123"}

        """
        let created = try TaskCreateScriptOutput.parse(stdout: stdout, homeDirectoryPath: "/Users/me")
        #expect(created == .init(directory: "/Users/me/repos/toastty-x", branch: "fix/x", baseRef: "abc123"))
    }

    @Test func createOutputErrors() {
        #expect(throws: TaskCreateScriptOutputError.missingJSONLine) { try TaskCreateScriptOutput.parse(stdout: "  \n") }
        #expect(throws: TaskCreateScriptOutputError.invalidJSON) { try TaskCreateScriptOutput.parse(stdout: "done") }
        #expect(throws: TaskCreateScriptOutputError.missingDirectory) { try TaskCreateScriptOutput.parse(stdout: #"{"branch":"b"}"#) }
        #expect(throws: TaskCreateScriptOutputError.directoryNotAbsolute("repos/x")) {
            try TaskCreateScriptOutput.parse(stdout: #"{"directory":"repos/x"}"#)
        }
        #expect(TaskCreateScriptOutput.failureDetail(stderr: "warning\nerror: branch exists\n\n") == "error: branch exists")
    }

    private let plan = TaskInboxItem.Plan(
        workspaceID: UUID(), title: "Fix the dot", slug: "ios-unread-dot", branchPrefix: "fix",
        profileID: "claude", model: nil, effort: nil
    )

    @Test func skillLineUsesEachAgentsSyntax() {
        #expect(TaskStartPrompt.skillLine(skill: "task-start", agent: .claude, isUserSkill: true) == "/toastty-user:task-start")
        #expect(TaskStartPrompt.skillLine(skill: "task-start", agent: .codex, isUserSkill: true) == "$toastty-user:task-start")
        #expect(TaskStartPrompt.skillLine(skill: "review", agent: .claude, isUserSkill: false) == "/review")
        #expect(TaskStartPrompt.skillLine(skill: "review", agent: .codex, isUserSkill: false) == "$review")
        #expect(TaskStartPrompt.skillLine(skill: "task-start", agent: .pi, isUserSkill: true) == "Use the task-start skill for this task.")
    }

    @Test func promptPutsTheSkillFirstThenTaskFilesAndContext() {
        let prompt = TaskStartPrompt.compose(
            skillLine: "/toastty-user:task-start",
            text: "The dot stays on.\n",
            attachmentPaths: ["/tasks/a b.png"],
            plan: plan,
            workspaceTitle: "toastty",
            directory: "/repos/toastty-ios-unread-dot",
            createdDirectory: .init(directory: "/repos/toastty-ios-unread-dot", branch: "fix/ios-unread-dot", baseRef: "d18c9655")
        )
        #expect(prompt == """
        /toastty-user:task-start
        The dot stays on.

        Read the following files attached to this task on this Mac:
        '/tasks/a b.png'

        Task space: ios-unread-dot, in workspace toastty
        Directory: /repos/toastty-ios-unread-dot
        Branch: fix/ios-unread-dot, from d18c9655
        """)
    }

    @Test func promptWithoutASkillNeverStartsWithADash() {
        let prompt = TaskStartPrompt.compose(
            skillLine: nil, text: "--fix the flag parser", attachmentPaths: [], plan: plan,
            workspaceTitle: "toastty", directory: "/repos/toastty", createdDirectory: nil
        )
        #expect(prompt.hasPrefix("Task:\n--fix the flag parser\n\nTask space: ios-unread-dot"))
        #expect(prompt.contains("Branch:") == false)
    }
}
