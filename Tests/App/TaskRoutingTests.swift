import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// Answers triage from a queue, and records each prompt it was given.
final class FakeTriageRunner: TaskTriageRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<TaskTriage.Answer, TaskTriageFailure>] = []
    private var receivedPrompts: [String] = []
    private var heldUntilCancelled = false
    private var cancelledCount = 0
    private var beforeAnswer: (@MainActor @Sendable () -> Void)?

    func answer(_ result: Result<TaskTriage.Answer, TaskTriageFailure>) {
        lock.withLock { queued.append(result) }
    }

    /// Runs on the main actor before the next answer is returned.
    func runBeforeAnswering(_ body: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { beforeAnswer = body }
    }

    /// The next call waits until its task is cancelled.
    func holdUntilCancelled() {
        lock.withLock { heldUntilCancelled = true }
    }

    var prompts: [String] { lock.withLock { receivedPrompts } }
    var cancellations: Int { lock.withLock { cancelledCount } }

    func run(prompt: String, triage: TasksConfig.Triage) async -> Result<TaskTriage.Answer, TaskTriageFailure> {
        let hold = lock.withLock {
            receivedPrompts.append(prompt)
            return heldUntilCancelled
        }
        if hold {
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(10))
            }
            lock.withLock { cancelledCount += 1 }
            return .failure(.cancelled)
        }
        if let body = lock.withLock({ () -> (@MainActor @Sendable () -> Void)? in
            defer { beforeAnswer = nil }
            return beforeAnswer
        }) {
            await MainActor.run { body() }
        }
        return lock.withLock {
            queued.isEmpty ? .failure(.failed("no answer queued")) : queued.removeFirst()
        }
    }
}

/// Triage, the pick-a-workspace state and reopening, through the real
/// coordinator, reducer and agent launcher with a fake triage command.
@MainActor
struct TaskRoutingTests {
    typealias Fixture = TaskCoordinatorTests.Fixture

    private static let triageConfig = TasksConfig.Triage(command: "fake-triage")

    private func makeFixture(triage: Bool = true) throws -> Fixture {
        let fixture = try Fixture()
        fixture.config = TasksConfig(
            triage: triage ? Self.triageConfig : nil,
            defaults: .init(agent: "claude", model: "claude-opus-5-5", effort: "high")
        )
        return fixture
    }

    private func sentText(_ fixture: Fixture, _ record: TaskRecord) throws -> String {
        let panelID = try #require(record.operation.taskSpace?.panelID)
        return try #require(fixture.router.sentTextByPanelID[panelID])
    }

    private func inputJSON(_ prompt: String) throws -> [String: Any] {
        let json = try #require(prompt.components(separatedBy: "INPUT:\n").last)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func triageChoosesWhatTheCallerLeftOutThenTheTaskStarts() async throws {
        let fixture = try makeFixture()
        fixture.config.workspaces = [TasksConfig.Workspace(path: fixture.projectRoot, guidelines: "Read AGENTS.md first.")]
        fixture.triage.answer(.success(TaskTriage.Answer(
            workspace: fixture.workspaceID.uuidString,
            agent: "codex",
            model: "gpt-6.1-sol",
            effort: "high",
            firstPrompt: "Start with the composer views. Start work at once.",
            title: "Composer keeps a blank line",
            slug: "composer-blank-line",
            reason: "A composer bug in toastty."
        )))

        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: "composer keeps a blank line after send, on mac and iphone"
        ))
        #expect(created.setup == .routing)
        #expect(created.workspaceID == nil)
        // Named from the first line until triage answers.
        #expect(created.title == "composer keeps a blank line after send, on mac and iphone")
        await fixture.waitUntil("the task starts") { fixture.record(created.id)?.setup == .started }

        let record = try #require(fixture.record(created.id))
        #expect(record.workspaceID == fixture.workspaceID)
        #expect(record.projectRoot == fixture.projectRoot)
        #expect(record.resolved == TaskFields(
            workspaceID: fixture.workspaceID,
            agent: "codex",
            model: "gpt-6.1-sol",
            effort: "high",
            prompt: "Start with the composer views. Start work at once."
        ))
        #expect(record.title == "Composer keeps a blank line")
        #expect(record.slug == "composer-blank-line")
        #expect(record.triageNote == nil)
        let taskSpaceID = try #require(record.taskSpaceWorkspaceID)
        #expect(fixture.store.state.workspacesByID[taskSpaceID]?.title == "composer-blank-line")
        #expect(fixture.store.state.workspacesByID[taskSpaceID]?.parentWorkspaceID == fixture.workspaceID)

        // The agent gets triage's first prompt, then the text exactly as
        // written.
        let sent = try sentText(fixture, record)
        #expect(sent.contains("gpt-6.1-sol"))
        #expect(sent.contains("Start with the composer views. Start work at once."))
        #expect(sent.contains("composer keeps a blank line after send, on mac and iphone"))

        // Triage saw the task, the open workspace with its root and
        // guidelines, and the installed agents.
        let prompt = try #require(fixture.triage.prompts.first)
        #expect(fixture.triage.prompts.count == 1)
        let input = try inputJSON(prompt)
        #expect((input["task"] as? [String: Any])?["text"] as? String == "composer keeps a blank line after send, on mac and iphone")
        let workspaces = try #require(input["workspaces"] as? [[String: String]])
        #expect(workspaces == [[
            "id": fixture.workspaceID.uuidString,
            "title": "toastty",
            "root": fixture.projectRoot,
            "guidelines": "Read AGENTS.md first.",
        ]])
        #expect((input["agents"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["claude", "codex"])
    }

    @Test func aCallerWhoChoseEverythingSkipsTriage() async throws {
        let fixture = try makeFixture()
        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: "Split out the parser",
            workspaceID: fixture.workspaceID,
            agent: "codex",
            model: "gpt-6.1-sol",
            effort: "high",
            prompt: "You own the parser split."
        ))
        #expect(created.setup == .settingUp)
        await fixture.waitForSetup(created.id)
        #expect(fixture.record(created.id)?.setup == .started)
        #expect(fixture.triage.prompts.isEmpty)
    }

    @Test func aPinnedValueThatCannotWorkFailsBeforeTriage() async throws {
        let fixture = try makeFixture()
        do {
            _ = try await fixture.coordinator.create(TaskCreateRequest(text: "x", agent: "gemini"))
            Issue.record("a bad pinned agent was accepted")
        } catch {
            #expect(error.localizedDescription.contains("gemini"))
        }
        do {
            _ = try await fixture.coordinator.create(TaskCreateRequest(text: "x", model: "two words"))
            Issue.record("a bad pinned model was accepted")
        } catch {
            #expect(error.localizedDescription.contains("one word"))
        }
        #expect(fixture.coordinator.records.records.isEmpty)
        #expect(fixture.triage.prompts.isEmpty)
    }

    @Test func whenTriageCannotPlaceATaskThePickedWorkspaceIsFixedForASecondTriage() async throws {
        let fixture = try makeFixture()
        fixture.triage.answer(.success(TaskTriage.Answer(
            workspace: nil,
            title: "Billing page shows the old plan",
            reason: "None of the open workspaces has a billing page."
        )))
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "billing page shows the old plan after upgrade"))
        await fixture.waitUntil("triage ends") { fixture.record(created.id)?.setup != .routing }
        let waiting = try #require(fixture.record(created.id))
        #expect(waiting.setup == .needsWorkspace(reason: "None of the open workspaces has a billing page."))
        #expect(waiting.title == "Billing page shows the old plan")
        #expect(fixture.taskSpaceIDs.isEmpty)

        fixture.triage.answer(.success(TaskTriage.Answer(agent: "codex", firstPrompt: "Check the plan cache.")))
        try fixture.coordinator.setWorkspace(taskID: created.id, choice: .open(fixture.workspaceID))
        await fixture.waitUntil("the task starts") { fixture.record(created.id)?.setup == .started }

        let record = try #require(fixture.record(created.id))
        #expect(record.pinned.workspaceID == fixture.workspaceID)
        #expect(record.resolved?.agent == "codex")
        #expect(record.resolved?.prompt == "Check the plan cache.")
        // The second triage had the workspace fixed and listed only it.
        let second = try inputJSON(try #require(fixture.triage.prompts.last))
        #expect((second["fixed"] as? [String: String])?["workspace"] == fixture.workspaceID.uuidString)
        #expect((second["choose"] as? [String])?.contains("workspace") == false)
        #expect((second["workspaces"] as? [[String: String]])?.count == 1)
    }

    @Test func aFailedOrUnusableTriageFallsBackToDefaults() async throws {
        let fixture = try makeFixture()
        fixture.triage.answer(.failure(.timedOut(seconds: 120)))
        let timedOut = try await fixture.coordinator.create(TaskCreateRequest(text: "one", workspaceID: fixture.workspaceID))
        await fixture.waitUntil("the first task starts") { fixture.record(timedOut.id)?.setup == .started }
        let first = try #require(fixture.record(timedOut.id))
        #expect(first.resolved == TaskFields(workspaceID: fixture.workspaceID, agent: "claude", model: "claude-opus-5-5", effort: "high"))
        #expect(first.triageNote == "Triage did not answer in 120 s.")

        fixture.triage.answer(.success(TaskTriage.Answer(agent: "gemini", model: "gemini-pro")))
        let unusable = try await fixture.coordinator.create(TaskCreateRequest(text: "two", workspaceID: fixture.workspaceID))
        await fixture.waitUntil("the second task starts") { fixture.record(unusable.id)?.setup == .started }
        let second = try #require(fixture.record(unusable.id))
        #expect(second.resolved?.agent == "claude")
        #expect(second.resolved?.model == "claude-opus-5-5")
        #expect(second.triageNote == "Toastty ignored triage's agent gemini, which is not an installed profile.")

        // With no workspace and a failed triage, the task waits for one.
        fixture.triage.answer(.failure(.failed("Not logged in")))
        let unplaced = try await fixture.coordinator.create(TaskCreateRequest(text: "three"))
        await fixture.waitUntil("the third task waits") { fixture.record(unplaced.id)?.setup != .routing }
        #expect(fixture.record(unplaced.id)?.setup == .needsWorkspace(reason: "Triage failed: Not logged in. Pick a workspace."))
    }

    @Test func withoutTriageATaskWithNoWorkspaceWaitsForThePick() async throws {
        let fixture = try makeFixture(triage: false)
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "Fix the unread dot"))
        #expect(created.setup == .needsWorkspace(reason: TaskCoordinator.noWorkspaceReason))

        try fixture.coordinator.setWorkspace(taskID: created.id, choice: .open(fixture.workspaceID))
        await fixture.waitUntil("the task starts") { fixture.record(created.id)?.setup == .started }
        #expect(fixture.record(created.id)?.resolved?.agent == "claude")
        #expect(fixture.triage.prompts.isEmpty)

        // The default agent and its settings are checked when the task is
        // made, not after the pick.
        do {
            _ = try await fixture.coordinator.create(TaskCreateRequest(text: "bad model", model: "two words"))
            Issue.record("a bad model was accepted without a workspace")
        } catch {
            #expect(error.localizedDescription.contains("one word"))
        }

        // Without triage or a default agent, nothing could ever start it.
        fixture.config.defaults = .init()
        do {
            _ = try await fixture.coordinator.create(TaskCreateRequest(text: "no agent"))
            Issue.record("a task with no possible agent was accepted")
        } catch {
            #expect(error.localizedDescription.contains("[defaults]"))
        }
    }

    @Test func pickingARecentWorkspaceOpensItAgainAndStartsThere() async throws {
        let fixture = try makeFixture(triage: false)
        let closedProject = fixture.root.appendingPathComponent("control-plane", isDirectory: true)
        try FileManager.default.createDirectory(at: closedProject.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let recent = RecentWorkspace(id: UUID(), title: "control-plane", rootDirectory: closedProject.path, closedAt: Date())
        fixture.recentWorkspaces.record(recent)
        #expect(fixture.coordinator.workspaceChoices().recent == [recent])
        #expect(fixture.coordinator.workspaceChoices().open.map(\.title) == ["toastty"])

        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "Rotate the relay key"))
        try fixture.coordinator.setWorkspace(taskID: created.id, choice: .recent(recent.id))
        await fixture.waitUntil("the task starts") { fixture.record(created.id)?.setup == .started }

        let record = try #require(fixture.record(created.id))
        let reopenedID = try #require(record.workspaceID)
        #expect(reopenedID != fixture.workspaceID)
        let reopened = try #require(fixture.store.state.workspacesByID[reopenedID])
        #expect(reopened.title == "control-plane")
        #expect(reopened.rootDirectory == closedProject.path)
        #expect(reopened.parentWorkspaceID == nil)
        #expect(record.projectRoot == closedProject.path)
        let taskSpaceID = try #require(record.taskSpaceWorkspaceID)
        #expect(fixture.store.state.workspacesByID[taskSpaceID]?.parentWorkspaceID == reopenedID)
        // Focus stays where the user was.
        #expect(fixture.store.selectedWorkspace?.id == fixture.workspaceID)

        // Now open, the project is no longer offered as recent, and
        // picking it again uses the open workspace.
        #expect(fixture.coordinator.workspaceChoices().recent.isEmpty)
        let second = try await fixture.coordinator.create(TaskCreateRequest(text: "Second relay task"))
        try fixture.coordinator.setWorkspace(taskID: second.id, choice: .recent(recent.id))
        #expect(fixture.record(second.id)?.workspaceID == reopenedID)
    }

    @Test func triageSuggestsAProjectThatIsNotOpenAndPickingItOpensIt() async throws {
        let fixture = try makeFixture()
        let website = fixture.root.appendingPathComponent("website", isDirectory: true)
        let controlPlane = fixture.root.appendingPathComponent("control-plane", isDirectory: true)
        for project in [website, controlPlane] {
            try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        }
        // The open project's section is not offered as closed.
        fixture.config.workspaces = [
            TasksConfig.Workspace(path: website.path, guidelines: "The marketing site."),
            TasksConfig.Workspace(path: fixture.projectRoot),
        ]
        fixture.recentWorkspaces.record(RecentWorkspace(id: UUID(), title: "control-plane", rootDirectory: controlPlane.path, closedAt: Date()))
        let websiteRoot = TasksConfigFile.normalizedPath(website.path)
        let workspaceCount = fixture.store.state.workspacesByID.count

        fixture.triage.answer(.success(TaskTriage.Answer(
            workspace: website.path,
            agent: "codex",
            title: "Pricing page typo",
            reason: "It is about the website, which is not open."
        )))
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "pricing page has a typo"))
        await fixture.waitUntil("triage ends") { fixture.record(created.id)?.setup != .routing }

        // The task waits with the suggestion; nothing opened on its own.
        let waiting = try #require(fixture.record(created.id))
        #expect(waiting.setup == .needsWorkspace(reason: "It is about the website, which is not open."))
        #expect(waiting.suggestedWorkspace == TaskWorkspaceSuggestion(title: "website", rootDirectory: websiteRoot))
        #expect(waiting.triageNote == nil)
        #expect(fixture.store.state.workspacesByID.count == workspaceCount)

        // Triage saw the closed projects, recent first, with the configured
        // one's guidelines.
        let input = try inputJSON(try #require(fixture.triage.prompts.first))
        #expect(input["closed_workspaces"] as? [[String: String]] == [
            ["title": "control-plane", "root": TasksConfigFile.normalizedPath(controlPlane.path)],
            ["title": "website", "root": websiteRoot, "guidelines": "The marketing site."],
        ])

        // The picker offers it first, as a directory to open.
        let choices = fixture.coordinator.workspaceChoices(taskID: created.id)
        #expect(choices.suggested == .init(title: "website", rootDirectory: websiteRoot, choice: .directory(websiteRoot)))
        #expect(TaskInboxCard.startTitle(for: choices.suggested?.choice, choices: choices) == "Open website & Start")

        fixture.triage.answer(.success(TaskTriage.Answer(agent: "codex")))
        try fixture.coordinator.setWorkspace(taskID: created.id, choice: .directory(websiteRoot))
        await fixture.waitUntil("the task starts") { fixture.record(created.id)?.setup == .started }
        let record = try #require(fixture.record(created.id))
        let openedID = try #require(record.workspaceID)
        let opened = try #require(fixture.store.state.workspacesByID[openedID])
        #expect(opened.title == "website")
        #expect(opened.rootDirectory == websiteRoot)
        #expect(opened.parentWorkspaceID == nil)
        #expect(record.projectRoot == websiteRoot)
        #expect(record.suggestedWorkspace == nil)
        // Focus stays where the user was.
        #expect(fixture.store.selectedWorkspace?.id == fixture.workspaceID)
    }

    @Test func aSuggestionThatWasClosedOrOpenedSinceIsChosenThatWay() async throws {
        let fixture = try makeFixture()
        let controlPlane = fixture.root.appendingPathComponent("control-plane", isDirectory: true)
        try FileManager.default.createDirectory(at: controlPlane.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let recent = RecentWorkspace(id: UUID(), title: "control-plane", rootDirectory: controlPlane.path, closedAt: Date())
        fixture.recentWorkspaces.record(recent)
        fixture.triage.answer(.success(TaskTriage.Answer(workspace: controlPlane.path, reason: "A control-plane bug.")))
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "relay key rotation fails"))
        await fixture.waitUntil("triage ends") { fixture.record(created.id)?.setup != .routing }

        // A recently closed workspace reopens with its own title.
        var choices = fixture.coordinator.workspaceChoices(taskID: created.id)
        #expect(choices.suggested?.choice == .recent(recent.id))
        #expect(TaskInboxCard.startTitle(for: choices.suggested?.choice, choices: choices) == "Open control-plane & Start")

        // Opened by the user meanwhile: the suggestion is that workspace.
        let openedID = UUID()
        #expect(fixture.store.send(.reopenWorkspace(
            windowID: try #require(fixture.store.state.windows.first?.id),
            workspaceID: openedID,
            panelID: UUID(),
            title: "control-plane",
            rootDirectory: controlPlane.path
        )))
        choices = fixture.coordinator.workspaceChoices(taskID: created.id)
        #expect(choices.suggested?.choice == .open(openedID))
        #expect(TaskInboxCard.startTitle(for: choices.suggested?.choice, choices: choices) == "Start in control-plane")
        #expect(TaskInboxCard.startTitle(for: nil, choices: choices) == "Start")

        // A suggestion that is only a directory now, such as a renamed
        // workspace that left the recent list, keeps its saved title.
        let renamed = fixture.root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
        var record = TaskRecord(createdAt: Date(), text: "x", title: "x", slug: "x", source: .cli, setup: .needsWorkspace(reason: "Not open."))
        record.suggestedWorkspace = TaskWorkspaceSuggestion(title: "My Project", rootDirectory: renamed.path)
        try fixture.coordinator.records.insert(record)
        choices = fixture.coordinator.workspaceChoices(taskID: record.id)
        #expect(choices.suggested?.choice == .directory(renamed.path))
        #expect(TaskInboxCard.startTitle(for: choices.suggested?.choice, choices: choices) == "Open My Project & Start")
        try fixture.coordinator.setWorkspace(taskID: record.id, choice: .directory(renamed.path))
        let opened = try #require(fixture.record(record.id)?.workspaceID)
        #expect(fixture.store.state.workspacesByID[opened]?.title == "My Project")
    }

    @Test func deleteStopsARunningTriage() async throws {
        let fixture = try makeFixture()
        fixture.triage.holdUntilCancelled()

        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "x"))
        await fixture.waitUntil("triage starts") { fixture.triage.prompts.count == 1 }
        try fixture.coordinator.delete(taskID: created.id)
        await fixture.waitUntil("triage is stopped") { fixture.triage.cancellations == 1 }
        #expect(fixture.record(created.id) == nil)
        #expect(fixture.taskSpaceIDs.isEmpty)
    }

    @Test func aPinnedWorkspaceThatClosedSendsTheTaskBackToThePicker() async throws {
        let fixture = try makeFixture()
        let windowID = try #require(fixture.store.state.windows.first?.id)
        _ = fixture.store.send(.createWorkspace(windowID: windowID, title: "scratch", activate: false))
        let scratch = try #require(fixture.store.state.workspacesByID.values.first { $0.title == "scratch" })
        _ = fixture.store.send(.setWorkspaceRootDirectory(workspaceID: scratch.id, rootDirectory: fixture.projectRoot))

        // Closed before routing starts: triage is not asked, so it cannot
        // move the task to another workspace.
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "x", workspaceID: scratch.id))
        _ = fixture.store.send(.closeWorkspace(workspaceID: scratch.id))
        await fixture.waitUntil("routing ends") { fixture.record(created.id)?.setup != .routing }
        #expect(fixture.record(created.id)?.setup == .needsWorkspace(reason: "The task's workspace closed. Pick a workspace."))
        #expect(fixture.triage.prompts.isEmpty)

        // Closed while triage runs: its choice of another workspace is not used.
        _ = fixture.store.send(.createWorkspace(windowID: windowID, title: "scratch 2", activate: false))
        let scratch2 = try #require(fixture.store.state.workspacesByID.values.first { $0.title == "scratch 2" })
        _ = fixture.store.send(.setWorkspaceRootDirectory(workspaceID: scratch2.id, rootDirectory: fixture.projectRoot))
        fixture.triage.runBeforeAnswering { [store = fixture.store] in
            _ = store.send(.closeWorkspace(workspaceID: scratch2.id))
        }
        fixture.triage.answer(.success(TaskTriage.Answer(workspace: fixture.workspaceID.uuidString, agent: "codex")))
        let second = try await fixture.coordinator.create(TaskCreateRequest(text: "y", workspaceID: scratch2.id))
        await fixture.waitUntil("routing ends") { fixture.record(second.id)?.setup != .routing }
        #expect(fixture.record(second.id)?.setup == .needsWorkspace(reason: "The task's workspace closed. Pick a workspace."))
        #expect(fixture.taskSpaceIDs.isEmpty)
    }

    @Test func anOverlongTriagePromptIsLeftOutAndTheTaskStillStarts() async throws {
        let fixture = try makeFixture()
        let text = String(repeating: "x", count: 60 * 1024)
        fixture.triage.answer(.success(TaskTriage.Answer(agent: "codex", firstPrompt: String(repeating: "p", count: 8 * 1024))))
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: text, workspaceID: fixture.workspaceID))
        await fixture.waitUntil("the task starts") { fixture.record(created.id)?.setup == .started }
        let record = try #require(fixture.record(created.id))
        #expect(record.resolved?.agent == "codex")
        #expect(record.resolved?.prompt == nil)
        #expect(record.triageNote == "Toastty left out triage's first prompt, which made the agent's first message longer than 64 KB.")
    }

    @Test func triageIsOfferedOnlyAgentsThatTakeThePinnedSettings() async throws {
        let fixture = try makeFixture()
        fixture.triage.answer(.success(TaskTriage.Answer(agent: "codex")))
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "x", workspaceID: fixture.workspaceID, effort: "low"))
        await fixture.waitUntil("the task starts") { fixture.record(created.id)?.setup == .started }
        let input = try inputJSON(try #require(fixture.triage.prompts.first))
        let offered = (input["agents"] as? [[String: Any]])?.filter { $0["accepts_effort"] as? Bool == false }
        #expect(offered?.isEmpty == true)
        #expect(fixture.record(created.id)?.resolved?.effort == "low")
    }

    @Test func aRestartRunsUnfinishedTriageAgain() async throws {
        let fixture = try makeFixture()
        let saved = TaskRecord(
            createdAt: Date(),
            text: "Fix the unread dot",
            title: "Fix the unread dot",
            slug: "fix-the-unread-dot",
            source: .cli,
            setup: .routing
        )
        try fixture.coordinator.records.insert(saved)
        fixture.triage.answer(.success(TaskTriage.Answer(workspace: fixture.workspaceID.uuidString, agent: "codex")))

        let relaunched = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        fixture.replaceCoordinator(relaunched)
        relaunched.reconcileAfterLaunch()
        await fixture.waitUntil("the task starts") { fixture.record(saved.id)?.setup == .started }
        #expect(fixture.record(saved.id)?.resolved?.agent == "codex")
        #expect(fixture.triage.prompts.count == 1)
    }

    @Test func retryRunsTriageAgainForATaskThatHasNoWorkspace() async throws {
        let fixture = try makeFixture()
        fixture.triage.answer(.success(TaskTriage.Answer(reason: "Unclear.")))
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "toastty: fix the unread dot"))
        await fixture.waitUntil("triage ends") { fixture.record(created.id)?.setup != .routing }
        #expect(fixture.record(created.id)?.setup == .needsWorkspace(reason: "Unclear."))

        fixture.triage.answer(.success(TaskTriage.Answer(workspace: fixture.projectRoot)))
        try fixture.coordinator.retry(taskID: created.id)
        await fixture.waitUntil("the task starts") { fixture.record(created.id)?.setup == .started }
        #expect(fixture.record(created.id)?.workspaceID == fixture.workspaceID)
        #expect(fixture.triage.prompts.count == 2)
    }
}

/// The last closed top-level workspaces, recorded from store actions.
@MainActor
struct RecentWorkspacesStoreTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-recent-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("recent-workspaces.json")
    }

    @Test func closingAWorkspaceOrItsLastTabRecordsItButNotASubspace() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let recents = RecentWorkspacesStore.inMemory()
        recents.observe(store, now: { Date(timeIntervalSince1970: 1_000) })
        let windowID = try #require(store.state.windows.first?.id)
        func makeWorkspace(_ title: String, root: String) throws -> WorkspaceState {
            _ = store.send(.createWorkspace(windowID: windowID, title: title, activate: false))
            let workspace = try #require(store.state.workspacesByID.values.first { $0.title == title })
            _ = store.send(.setWorkspaceRootDirectory(workspaceID: workspace.id, rootDirectory: root))
            return workspace
        }
        let controlPlane = try makeWorkspace("control-plane", root: "/tmp/control-plane")
        let subspace = try makeWorkspace("task-space", root: "/tmp/task-space")
        _ = store.send(.setWorkspaceRootDirectory(workspaceID: subspace.id, rootDirectory: nil))
        _ = store.send(.setWorkspaceParent(workspaceID: subspace.id, parentWorkspaceID: controlPlane.id, spawningSessionID: nil))

        _ = store.send(.closeWorkspace(workspaceID: subspace.id))
        #expect(recents.items.isEmpty)
        _ = store.send(.closeWorkspace(workspaceID: controlPlane.id))
        #expect(recents.items == [RecentWorkspace(
            id: controlPlane.id,
            title: "control-plane",
            rootDirectory: "/tmp/control-plane",
            closedAt: Date(timeIntervalSince1970: 1_000)
        )])

        // Closing a workspace's last tab removes it too.
        let website = try makeWorkspace("website", root: "/tmp/website")
        _ = store.send(.closeWorkspaceTab(workspaceID: website.id, tabID: try #require(website.tabIDs.first)))
        #expect(store.state.workspacesByID[website.id] == nil)
        #expect(recents.items.map(\.title) == ["website", "control-plane"])
    }

    @Test func entriesAreNewestFirstOnePerRootAndSurviveARelaunch() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let recents = RecentWorkspacesStore(fileURL: file, maxItems: 3, persistDebounceInterval: 0)
        let older = RecentWorkspace(id: UUID(), title: "api", rootDirectory: "/tmp/api", closedAt: Date(timeIntervalSince1970: 1))
        recents.record(older)
        for index in 0..<3 {
            recents.record(RecentWorkspace(id: UUID(), title: "p\(index)", rootDirectory: "/tmp/p\(index)", closedAt: Date(timeIntervalSince1970: 10)))
        }
        let newerAPI = RecentWorkspace(id: UUID(), title: "api again", rootDirectory: "/tmp/api/", closedAt: Date(timeIntervalSince1970: 20))
        recents.record(newerAPI)
        #expect(recents.items.map(\.title) == ["api again", "p2", "p1"])
        recents.flushForTesting()

        let relaunched = RecentWorkspacesStore(fileURL: file, maxItems: 3)
        #expect(relaunched.items == recents.items)
    }
}

/// The live runner, with real `/bin/sh` commands standing in for a model CLI.
struct TaskLiveTriageRunnerTests {
    private func run(_ command: String, timeoutSeconds: Int = 10) async -> Result<TaskTriage.Answer, TaskTriageFailure> {
        await TaskLiveTriageRunner(pathOverride: "/usr/bin:/bin").run(
            prompt: "INPUT:\n{\"task\": {\"text\": \"fix it\"}}",
            triage: TasksConfig.Triage(command: command, timeoutSeconds: timeoutSeconds)
        )
    }

    @Test func theCommandGetsThePromptOnStdinAndAnswersOnStdout() async {
        // The answer depends on stdin, so it proves the prompt arrived.
        let result = await run(#"grep -q 'fix it' && printf '%s\n' 'Thinking...' '{"agent": "codex", "title": "Fix it"}'"#)
        #expect(result == .success(TaskTriage.Answer(agent: "codex", title: "Fix it")))
    }

    @Test func itRunsInAnEmptyTemporaryFolderWithoutToasttySessionVariables() async {
        let result = await run(#"[ -z "$(ls -A)" ] && [ -z "${TOASTTY_SESSION_ID:-}" ] && printf '{"agent": "%s"}' "$(basename "$(pwd)" | cut -c1-15)""#)
        #expect(result == .success(TaskTriage.Answer(agent: "toastty-triage-")))
    }

    @Test func failuresSayWhatWentWrong() async {
        #expect(await run("echo 'not logged in' >&2; exit 3") == .failure(.failed("not logged in")))
        #expect(await run("echo 'no json here'") == .failure(.failed("the command printed no JSON answer")))
        #expect(await run("sleep 30", timeoutSeconds: 1) == .failure(.timedOut(seconds: 1)))
    }
}
