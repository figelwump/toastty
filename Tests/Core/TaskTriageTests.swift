import CoreState
import Foundation
import Testing

struct TaskTriageTests {
    private let home = "/Users/tester"
    private let toastty = TaskTriage.Workspace(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
        title: "toastty",
        rootDirectory: "/Users/tester/repos/toastty",
        guidelines: "iOS tasks: read ios/AGENTS.md first."
    )
    private let website = TaskTriage.Workspace(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
        title: "website",
        rootDirectory: "/Users/tester/repos/website"
    )
    private let codex = TaskTriage.Agent(id: "codex", name: "Codex", acceptsModel: true, acceptsEffort: true)
    private let cursor = TaskTriage.Agent(id: "cursor", name: "Cursor", acceptsModel: true, acceptsEffort: false)

    private func answer(_ text: String) throws -> TaskTriage.Answer {
        try TaskTriage.answer(fromOutput: Data(text.utf8))
    }

    // MARK: - When triage runs

    @Test
    func triageRunsOnlyForWhatTheCallerLeftOut() {
        let all = TaskFields(agent: "codex", model: "gpt-6.1-sol", effort: "high", prompt: "Fix it.")
        #expect(TaskTriage.missingFields(pinned: all, workspaceID: toastty.id, pinnedAgent: codex).isEmpty)

        // An agent that takes no effort needs none.
        let cursorTask = TaskFields(agent: "cursor", model: "auto", prompt: "Fix it.")
        #expect(TaskTriage.missingFields(pinned: cursorTask, workspaceID: toastty.id, pinnedAgent: cursor).isEmpty)

        #expect(TaskTriage.missingFields(pinned: TaskFields(), workspaceID: nil, pinnedAgent: nil)
            == [.workspace, .agent, .model, .effort, .prompt])
        let noPrompt = TaskFields(agent: "codex", model: "gpt-6.1-sol", effort: "high")
        #expect(TaskTriage.missingFields(pinned: noPrompt, workspaceID: toastty.id, pinnedAgent: codex) == [.prompt])
        // A title and slug alone never start triage.
        let titled = TaskFields(agent: "codex", model: "m", effort: "high", prompt: "p")
        #expect(TaskTriage.missingFields(pinned: titled, workspaceID: toastty.id, pinnedAgent: codex).isEmpty)
    }

    // MARK: - Input

    @Test
    func inputListsTheChoicesAndKeepsTheTaskAsData() throws {
        let input = TaskTriage.Input(
            text: "Composer keeps a blank line\nafter send",
            fileNames: ["shot.png"],
            fixed: TaskFields(agent: "codex", title: "Composer blank line"),
            fixedWorkspace: nil,
            workspaces: [toastty, website],
            agents: [codex],
            guidelines: "Bugs: codex."
        )
        let prompt = TaskTriage.prompt(for: input)
        #expect(prompt.hasPrefix(TaskTriage.instructions))
        let json = try #require(prompt.components(separatedBy: "INPUT:\n").last)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["choose"] as? [String] == ["workspace", "model", "effort", "first_prompt", "slug"])
        #expect((object["fixed"] as? [String: String]) == ["agent": "codex", "title": "Composer blank line"])
        let task = try #require(object["task"] as? [String: Any])
        #expect(task["text"] as? String == "Composer keeps a blank line\nafter send")
        #expect(task["files"] as? [String] == ["shot.png"])
        let workspaces = try #require(object["workspaces"] as? [[String: String]])
        #expect(workspaces.map { $0["title"] } == ["toastty", "website"])
        #expect(workspaces[0]["root"] == "/Users/tester/repos/toastty")
        #expect(workspaces[0]["guidelines"] == "iOS tasks: read ios/AGENTS.md first.")
        #expect(workspaces[1]["guidelines"] == nil)
        #expect(object["guidelines"] as? String == "Bugs: codex.")
    }

    @Test
    func aFixedWorkspaceIsTheOnlyOneListed() throws {
        let input = TaskTriage.Input(
            text: "x",
            fileNames: [],
            fixed: TaskFields(),
            fixedWorkspace: website,
            workspaces: [toastty, website],
            agents: [codex],
            guidelines: nil
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(TaskTriage.inputJSON(for: input).utf8)) as? [String: Any]
        )
        #expect((object["workspaces"] as? [[String: String]])?.map { $0["title"] } == ["website"])
        #expect((object["fixed"] as? [String: String])?["workspace"] == website.id.uuidString)
        #expect((object["choose"] as? [String])?.contains("workspace") == false)
    }

    // MARK: - Answer

    @Test
    func readsAPlainAnswer() throws {
        let parsed = try answer("""
        {"workspace": "\(toastty.id.uuidString)", "agent": "codex", "model": "gpt-6.1-sol", "effort": "high",
         "first_prompt": "Start work at once.", "title": "Composer blank line", "slug": "composer-blank-line",
         "reason": "A composer bug."}
        """)
        #expect(parsed == TaskTriage.Answer(
            workspace: toastty.id.uuidString,
            agent: "codex",
            model: "gpt-6.1-sol",
            effort: "high",
            firstPrompt: "Start work at once.",
            title: "Composer blank line",
            slug: "composer-blank-line",
            reason: "A composer bug."
        ))
    }

    @Test
    func readsAnAnswerInsideAFenceOrAfterText() throws {
        let fenced = try answer("Here is my choice:\n```json\n{\"agent\": \"codex\", \"model\": null}\n```\n")
        #expect(fenced == TaskTriage.Answer(agent: "codex"))
        let prose = try answer("I picked codex. {\"agent\": \"codex\", \"effort\": 3} Done.")
        // A value that is not a string is ignored rather than failing the answer.
        #expect(prose == TaskTriage.Answer(agent: "codex"))
    }

    @Test
    func readsClaudeJSONOutput() throws {
        let wrapped = try answer(#"{"type":"result","subtype":"success","is_error":false,"result":"{\"agent\":\"claude\",\"title\":\"Billing\"}"}"#)
        #expect(wrapped == TaskTriage.Answer(agent: "claude", title: "Billing"))
        let structured = try answer(#"{"type":"result","is_error":false,"result":"","structured_output":{"agent":"codex"}}"#)
        #expect(structured == TaskTriage.Answer(agent: "codex"))
        #expect(throws: TaskTriage.OutputError.commandError("Not logged in · Please run /login")) {
            try answer(#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login\nmore"}"#)
        }
    }

    @Test
    func rejectsOutputWithoutAnAnswer() {
        #expect(throws: TaskTriage.OutputError.unreadable) { try answer("") }
        #expect(throws: TaskTriage.OutputError.unreadable) { try answer("I could not decide.") }
        #expect(throws: TaskTriage.OutputError.unreadable) { try answer(#"{"unrelated": true}"#) }
        #expect(throws: TaskTriage.OutputError.unreadable) { try answer("[1, 2]") }
    }

    // MARK: - Merge

    private func resolve(
        pinned: TaskFields = TaskFields(),
        workspaceID: UUID? = nil,
        _ answer: TaskTriage.Answer?
    ) -> TaskTriage.Resolution {
        TaskTriage.resolve(
            pinned: pinned,
            workspaceID: workspaceID,
            answer: answer,
            workspaces: [toastty, website],
            agents: [codex, cursor],
            homeDirectoryPath: home
        )
    }

    @Test
    func triageFillsOnlyWhatTheCallerLeftOut() {
        let resolution = resolve(
            pinned: TaskFields(agent: "cursor", prompt: "Mine.", title: "My title"),
            workspaceID: website.id,
            TaskTriage.Answer(
                workspace: toastty.id.uuidString,
                agent: "codex",
                model: "auto",
                effort: "high",
                firstPrompt: "Theirs.",
                title: "Their title",
                slug: "their-slug"
            )
        )
        #expect(resolution == TaskTriage.Resolution(
            workspaceID: website.id,
            agent: "cursor",
            model: "auto",
            // Cursor takes no effort, so triage's is dropped.
            effort: nil,
            prompt: "Mine.",
            title: "My title",
            slug: "their-slug"
        ))
    }

    @Test
    func aWorkspaceCanBeNamedByItsRootDirectory() {
        #expect(resolve(TaskTriage.Answer(workspace: "~/repos/website")).workspaceID == website.id)
        #expect(resolve(TaskTriage.Answer(workspace: "/Users/tester/repos/toastty/")).workspaceID == toastty.id)
    }

    @Test
    func anUnknownWorkspaceLeavesTheTaskForTheUser() {
        let unknown = resolve(TaskTriage.Answer(workspace: "billing-service", reason: "No workspace has a billing page."))
        #expect(unknown.workspaceID == nil)
        #expect(unknown.workspaceReason == "No workspace has a billing page.")
        #expect(unknown.rejected == ["workspace billing-service, which is not an open workspace"])

        let none = resolve(TaskTriage.Answer(agent: "codex"))
        #expect(none.workspaceID == nil)
        #expect(none.workspaceReason == "Triage did not choose an open workspace.")
        #expect(none.rejected.isEmpty)

        // Two open workspaces on one root: the root names neither.
        let twin = TaskTriage.Workspace(id: UUID(), title: "toastty 2", rootDirectory: toastty.rootDirectory)
        let ambiguous = TaskTriage.resolve(
            pinned: TaskFields(),
            workspaceID: nil,
            answer: TaskTriage.Answer(workspace: toastty.rootDirectory),
            workspaces: [toastty, twin],
            agents: [codex],
            homeDirectoryPath: home
        )
        #expect(ambiguous.workspaceID == nil)
    }

    @Test
    func unusableChoicesAreDroppedAndNamed() {
        let resolution = resolve(
            workspaceID: toastty.id,
            TaskTriage.Answer(
                agent: "gemini",
                model: "--dangerous",
                firstPrompt: String(repeating: "a", count: TaskTriage.maximumFirstPromptUTF8Count + 1),
                title: "  Line one\nline two",
                slug: "Not A Slug!"
            )
        )
        #expect(resolution.agent == nil)
        // No agent was chosen, so its model is not checked or kept.
        #expect(resolution.model == nil)
        #expect(resolution.prompt == nil)
        #expect(resolution.title == "Line one")
        #expect(resolution.slug == "not-a-slug")
        #expect(resolution.rejected == [
            "agent gemini, which is not an installed profile",
            "first_prompt, which is longer than 16 KB",
        ])

        let badModel = resolve(workspaceID: toastty.id, TaskTriage.Answer(agent: "codex", model: "two words", effort: "-x"))
        #expect(badModel.agent == "codex")
        #expect(badModel.model == nil)
        #expect(badModel.effort == nil)
        #expect(badModel.rejected == ["model two words, which is not one word", "effort -x, which is not one word"])
    }

    @Test
    func withoutAnAnswerOnlyTheCallersChoicesRemain() {
        let pinned = TaskFields(agent: "codex", model: "m")
        #expect(resolve(pinned: pinned, workspaceID: toastty.id, nil) == TaskTriage.Resolution(
            workspaceID: toastty.id,
            agent: "codex",
            model: "m"
        ))
    }
}
