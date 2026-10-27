import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// Runs task creation and setup through the real reducer, store and agent
/// launcher, with a fake terminal in place of Ghostty.
@MainActor
struct TaskCoordinatorTests {
    @MainActor
    final class Fixture {
        let store = AppStore(persistTerminalFontPreference: false)
        /// Status changes send no desktop notification: without notification
        /// access, as on CI, the access alert would block the test host.
        let sessionRuntimeStore = SessionRuntimeStore(sendSessionStatusNotification: { _, _, _, _, _ in })
        let router = TestTerminalCommandRouter()
        let root: URL
        /// A git repository root; the workspace terminal starts in a
        /// directory inside it.
        let projectRoot: String
        let attachmentsDirectory: URL
        let recordsFile: URL
        let launcher: AgentLaunchService
        let workspaceID: UUID
        var config = TasksConfig()
        var configError: (any Error)?
        /// Answers triage when a test turns it on with `[triage] command`.
        let triage = FakeTriageRunner()
        let recentWorkspaces = RecentWorkspacesStore.inMemory()
        /// The coordinator's clock, when a test moves it; else the real time.
        var clock: Date?
        private(set) var scopeGrants: [(sessionID: String, workspaceID: UUID)] = []
        private(set) var coordinator: TaskCoordinator!

        init(readinessTimeout: Duration = .seconds(3)) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("toastty-tasks-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            let project = root.appendingPathComponent("project", isDirectory: true)
            let subdirectory = project.appendingPathComponent("Sources", isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            for directory in [subdirectory, project.appendingPathComponent(".git", isDirectory: true), bin] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            projectRoot = project.path
            attachmentsDirectory = root.appendingPathComponent("task-attachments", isDirectory: true)
            recordsFile = root.appendingPathComponent("task-records.json")
            var executables: [String: String] = [:]
            for name in ["claude", "codex"] {
                let path = bin.appendingPathComponent(name).path
                FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
                executables[name] = path
            }

            sessionRuntimeStore.bind(store: store)
            router.defaultPromptState = .idleAtPrompt
            let workspace = try #require(store.selectedWorkspace)
            workspaceID = workspace.id
            _ = store.send(.renameWorkspace(workspaceID: workspaceID, title: "toastty"))
            _ = store.send(.updateTerminalPanelMetadata(
                panelID: try #require(workspace.focusedPanelID),
                title: nil,
                cwd: subdirectory.path
            ))
            launcher = AgentLaunchService(
                store: store,
                terminalCommandRouter: router,
                sessionRuntimeStore: sessionRuntimeStore,
                agentCatalogProvider: TestAgentCatalogProvider(profiles: [
                    AgentProfile(id: "claude", displayName: "Claude Code", argv: [try #require(executables["claude"])]),
                    AgentProfile(id: "codex", displayName: "Codex", argv: [try #require(executables["codex"])]),
                ]),
                cliExecutablePathProvider: { "/bin/sh" },
                socketPathProvider: { "/tmp/toastty-tests.sock" }
            )
            coordinator = makeCoordinator(records: TaskRecordStore(fileURL: recordsFile), readinessTimeout: readinessTimeout)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// A coordinator as a new app launch would make one, over `records`.
        func makeCoordinator(records: TaskRecordStore, readinessTimeout: Duration = .seconds(3)) -> TaskCoordinator {
            TaskCoordinator(
                records: records,
                store: store,
                launcher: launcher,
                configLoader: { [unowned self] in
                    if let configError { throw configError }
                    return config
                },
                attachmentsDirectoryURL: attachmentsDirectory,
                hasActiveSession: { [unowned self] workspaceID in
                    let registry = sessionRuntimeStore.sessionRegistry
                    return registry.activeSessionIDByPanelID.values.contains {
                        registry.sessionsByID[$0]?.workspaceID == workspaceID
                    }
                },
                grantScope: { [unowned self] sessionID, workspaceID in
                    scopeGrants.append((sessionID, workspaceID))
                },
                now: { [unowned self] in clock ?? Date() },
                terminalReadinessTimeout: readinessTimeout,
                triageRunner: triage,
                recentWorkspaces: recentWorkspaces
            )
        }

        func replaceCoordinator(_ coordinator: TaskCoordinator) {
            self.coordinator = coordinator
        }

        var taskSpaceIDs: [UUID] { store.state.subspaceWorkspaceIDs(of: workspaceID) }

        func record(_ id: UUID) -> TaskRecord? { coordinator.records.record(id: id) }

        func waitUntil(_ description: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while condition() == false {
                guard ContinuousClock.now < deadline else {
                    Issue.record("Timed out waiting until \(description)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        func waitForSetup(_ id: UUID) async {
            await waitUntil("setup ends") { record(id)?.setup != .settingUp }
        }

        /// The record as saved on disk, read without the in-memory store.
        func savedRecord(_ id: UUID) -> TaskRecord? {
            TaskRecordStore(fileURL: recordsFile).record(id: id)
        }
    }

    @Test func aWorkspaceSavesOnlyAGitRootAsItsProjectRoot() async throws {
        let fixture = try Fixture()
        let panelID = try #require(fixture.store.state.workspacesByID[fixture.workspaceID]?.focusedPanelID)
        let plain = fixture.root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        _ = fixture.store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: plain.path))

        // A terminal outside any repository, like a new one in the home
        // folder, places this task there but is not saved.
        let first = try await fixture.coordinator.create(TaskCreateRequest(text: "outside", workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(first.id)
        #expect(fixture.record(first.id)?.projectRoot == plain.path)
        #expect(fixture.store.state.workspacesByID[fixture.workspaceID]?.rootDirectory == nil)

        // After `cd` into the project, the next task finds and saves its root.
        _ = fixture.store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: fixture.projectRoot + "/Sources"))
        let second = try await fixture.coordinator.create(TaskCreateRequest(text: "inside", workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(second.id)
        #expect(fixture.record(second.id)?.projectRoot == fixture.projectRoot)
        #expect(fixture.store.state.workspacesByID[fixture.workspaceID]?.rootDirectory == fixture.projectRoot)
    }

    @Test func createStartsTheAgentInANewTaskSpace() async throws {
        let fixture = try Fixture()
        fixture.config.defaults.startSkill = "task-start"
        let screenshot = fixture.root.appendingPathComponent("repro shot.png")
        try Data("png".utf8).write(to: screenshot)

        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: "Composer keeps a blank line after send\nOn Mac and iPhone.",
            files: [screenshot.path],
            workspaceID: fixture.workspaceID,
            agent: "codex",
            model: "gpt-6.1-sol",
            effort: "high",
            prompt: "Fix the composer. Start work at once."
        ))
        // The call returns before setup ends.
        #expect(created.setup == .settingUp)
        #expect(created.title == "Composer keeps a blank line after send")
        #expect(created.slug == "composer-keeps-a-blank-line-after-send")
        await fixture.waitForSetup(created.id)

        let record = try #require(fixture.record(created.id))
        #expect(record.setup == .started)
        #expect(record.projectRoot == fixture.projectRoot)
        // The project root came from the terminal's git root and was saved
        // on the workspace for later tasks.
        #expect(fixture.store.state.workspacesByID[fixture.workspaceID]?.rootDirectory == fixture.projectRoot)

        let taskSpaceID = try #require(fixture.taskSpaceIDs.first)
        #expect(fixture.taskSpaceIDs.count == 1)
        #expect(record.taskSpaceWorkspaceID == taskSpaceID)
        let taskSpace = try #require(fixture.store.state.workspacesByID[taskSpaceID])
        #expect(taskSpace.taskID == created.id)
        #expect(taskSpace.title == created.slug)
        #expect(taskSpace.hasBeenVisited == false)
        #expect(fixture.store.selectedWorkspace?.id == fixture.workspaceID)

        // The agent got the start skill, the first prompt, then the text as
        // written, then Toastty's copy of the file.
        let attachment = try #require(record.attachments.first)
        #expect(attachment.displayName == "repro shot.png")
        #expect(attachment.path.hasPrefix(fixture.attachmentsDirectory.path))
        #expect(try Data(contentsOf: URL(filePath: attachment.path)) == Data("png".utf8))
        let panelID = try #require(record.operation.taskSpace?.panelID)
        let sent = try #require(fixture.router.sentTextByPanelID[panelID])
        #expect(sent.contains("gpt-6.1-sol"))
        let skillLine = try #require(sent.range(of: "Use the task-start skill."))
        let firstPrompt = try #require(sent.range(of: "Fix the composer. Start work at once."))
        #expect(skillLine.upperBound < firstPrompt.lowerBound)
        #expect(sent.contains("On Mac and iPhone."))
        // The copy's folder is named by the task ID.
        #expect(sent.contains("task-attachments/\(created.id.uuidString)/repro"))
        #expect(fixture.router.focusPolicyByPanelID[panelID] == .preserveFirstResponder)

        // The session runs in the task space, unscoped so it can reach other
        // tasks, and the journal saved it to disk.
        let session = try #require(fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID))
        #expect(session.workspaceID == taskSpaceID)
        #expect(fixture.sessionRuntimeStore.isWorkspaceScoped(sessionID: session.sessionID) == false)
        #expect(record.operation.agentLaunch?.sessionID == session.sessionID)
        #expect(fixture.savedRecord(created.id)?.setup == .started)
    }

    @Test func defaultsFillOnlyTheFieldsTheCallerLeftOut() async throws {
        let fixture = try Fixture()
        fixture.config = TasksConfig(defaults: .init(agent: "claude", model: "claude-opus-5-5", effort: "high"))

        let defaulted = try await fixture.coordinator.create(TaskCreateRequest(text: "one", workspaceID: fixture.workspaceID))
        #expect(defaulted.resolved == TaskFields(workspaceID: fixture.workspaceID, agent: "claude", model: "claude-opus-5-5", effort: "high"))

        let pinnedEffort = try await fixture.coordinator.create(TaskCreateRequest(text: "two", workspaceID: fixture.workspaceID, effort: "low"))
        #expect(pinnedEffort.resolved?.effort == "low")
        #expect(pinnedEffort.resolved?.model == "claude-opus-5-5")

        // The default model belongs to the default agent, so another agent
        // gets its own default.
        let otherAgent = try await fixture.coordinator.create(TaskCreateRequest(text: "three", workspaceID: fixture.workspaceID, agent: "codex"))
        #expect(otherAgent.resolved?.agent == "codex")
        #expect(otherAgent.resolved?.model == nil)
        #expect(otherAgent.resolved?.effort == nil)
        #expect(otherAgent.pinned == TaskFields(workspaceID: fixture.workspaceID, agent: "codex"))

        for id in [defaulted.id, pinnedEffort.id, otherAgent.id] {
            await fixture.waitForSetup(id)
            #expect(fixture.record(id)?.setup == .started)
        }
        #expect(fixture.taskSpaceIDs.count == 3)
        #expect(Set(fixture.taskSpaceIDs.compactMap { fixture.store.state.workspacesByID[$0]?.title }) == ["one", "two", "three"])
    }

    @Test func badRequestsFailAtOnceAndSaveNothing() async throws {
        let fixture = try Fixture()
        func expectFailure(_ request: TaskCreateRequest, caller: TaskCaller = .unmanaged, mentioning text: String) async {
            do {
                try await fixture.coordinator.create(request, caller: caller)
                Issue.record("expected a failure mentioning \(text)")
            } catch {
                #expect(error.localizedDescription.contains(text), "\(error.localizedDescription)")
            }
        }

        await expectFailure(TaskCreateRequest(text: "x", workspaceID: fixture.workspaceID), mentioning: "[defaults]")
        await expectFailure(TaskCreateRequest(text: "x", workspaceID: fixture.workspaceID, agent: "gemini"), mentioning: "available: claude, codex")
        await expectFailure(TaskCreateRequest(text: "  ", workspaceID: fixture.workspaceID, agent: "codex"), mentioning: "needs text or a prompt")
        await expectFailure(TaskCreateRequest(text: "x", workspaceID: UUID(), agent: "codex"), mentioning: "No open workspace")
        await expectFailure(TaskCreateRequest(text: "x", slug: "Bad Slug", workspaceID: fixture.workspaceID, agent: "codex"), mentioning: "slug")
        await expectFailure(TaskCreateRequest(text: "x", title: "two\nlines", workspaceID: fixture.workspaceID, agent: "codex"), mentioning: "one line")
        await expectFailure(TaskCreateRequest(text: "x", workspaceID: fixture.workspaceID, agent: "codex", model: "gpt 6"), mentioning: "one word")
        await expectFailure(TaskCreateRequest(text: "x", files: [fixture.root.appendingPathComponent("missing.png").path], workspaceID: fixture.workspaceID, agent: "codex"), mentioning: "missing.png")
        await expectFailure(TaskCreateRequest(text: "x", files: [fixture.root.path], workspaceID: fixture.workspaceID, agent: "codex"), mentioning: "not a regular file")
        await expectFailure(TaskCreateRequest(text: "x", files: ["relative.png"], workspaceID: fixture.workspaceID, agent: "codex"), mentioning: "absolute path")
        await expectFailure(TaskCreateRequest(text: "x", clientRequestID: "has space", workspaceID: fixture.workspaceID, agent: "codex"), mentioning: "request ID")

        await expectFailure(TaskCreateRequest(text: String(repeating: "x", count: 70 * 1024), workspaceID: fixture.workspaceID, agent: "codex"), mentioning: "too long")
        await expectFailure(TaskCreateRequest(text: "a\u{0}b", workspaceID: fixture.workspaceID, agent: "codex"), mentioning: "NUL")

        fixture.configError = TasksConfigParseError(line: 4, message: "unknown table [create]")
        await expectFailure(TaskCreateRequest(text: "x", workspaceID: fixture.workspaceID, agent: "codex"), mentioning: "tasks.toml line 4")

        #expect(fixture.coordinator.records.records.isEmpty)
        #expect(fixture.taskSpaceIDs.isEmpty)
        #expect(fixture.store.state.workspacesByID[fixture.workspaceID]?.rootDirectory == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.attachmentsDirectory.path) == false)
    }

    @Test func aRepeatedRequestIDReturnsTheFirstTask() async throws {
        let fixture = try Fixture()
        let request = TaskCreateRequest(text: "once", clientRequestID: "req-42", workspaceID: fixture.workspaceID, agent: "codex")
        let first = try await fixture.coordinator.create(request)
        let second = try await fixture.coordinator.create(request)
        #expect(second.id == first.id)
        await fixture.waitForSetup(first.id)
        let third = try await fixture.coordinator.create(request)
        #expect(third.id == first.id)
        #expect(third.setup == .started)
        #expect(fixture.coordinator.records.records.count == 1)
        #expect(fixture.taskSpaceIDs.count == 1)
    }

    @Test func anAgentCallerDefaultsToItsOwnProjectAndGetsTheTaskSpaceInScope() async throws {
        let fixture = try Fixture()
        let parentTask = try await fixture.coordinator.create(TaskCreateRequest(text: "parent", workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(parentTask.id)
        let callerWorkspaceID = try #require(fixture.record(parentTask.id)?.taskSpaceWorkspaceID)
        let callerSessionID = try #require(fixture.record(parentTask.id)?.operation.agentLaunch?.sessionID)

        // The caller runs in a task space; the new task belongs to the
        // project above it.
        let child = try await fixture.coordinator.create(
            TaskCreateRequest(text: "child", agent: "claude"),
            caller: TaskCaller(sessionID: callerSessionID, workspaceID: callerWorkspaceID)
        )
        #expect(child.workspaceID == fixture.workspaceID)
        #expect(child.source == .agent(sessionID: callerSessionID))
        await fixture.waitForSetup(child.id)
        let childSpace = try #require(fixture.record(child.id)?.taskSpaceWorkspaceID)
        #expect(fixture.store.state.workspacesByID[childSpace]?.parentWorkspaceID == fixture.workspaceID)
        #expect(fixture.store.state.workspacesByID[childSpace]?.spawningSessionID == callerSessionID)
        // Only the agent that asked is offered the new task space.
        #expect(fixture.scopeGrants.map(\.sessionID) == [callerSessionID])
        #expect(fixture.scopeGrants.map(\.workspaceID) == [childSpace])
    }

    @Test func aFailedStartCanBeRetriedInTheSameTaskSpace() async throws {
        let fixture = try Fixture(readinessTimeout: .milliseconds(300))
        fixture.router.defaultPromptState = .exited
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "Fix the dot", workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(created.id)

        guard case .setupFailed(let reason)? = fixture.record(created.id)?.setup else {
            Issue.record("setup did not fail")
            return
        }
        #expect(reason.contains("did not get ready"))
        #expect(fixture.savedRecord(created.id)?.setup == .setupFailed(reason: reason))
        let taskSpaceID = try #require(fixture.record(created.id)?.taskSpaceWorkspaceID)
        #expect(fixture.taskSpaceIDs == [taskSpaceID])

        fixture.router.defaultPromptState = .idleAtPrompt
        try fixture.coordinator.retry(taskID: created.id)
        await fixture.waitForSetup(created.id)
        #expect(fixture.record(created.id)?.setup == .started)
        #expect(fixture.taskSpaceIDs == [taskSpaceID])
        #expect(throws: TaskError("This task has already started.")) {
            try fixture.coordinator.retry(taskID: created.id)
        }
    }

    @Test func uncertainDeliveryIsNotRetriedOnItsOwn() async throws {
        let fixture = try Fixture()
        fixture.router.sendFailure = .uncertain
        fixture.router.failingSendCount = 1
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "Fix the dot", workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(created.id)
        guard case .setupFailed(let reason)? = fixture.record(created.id)?.setup else {
            Issue.record("setup did not fail")
            return
        }
        #expect(reason.contains("may not have reached"))
        #expect(fixture.router.sendAttemptCount == 1)

        try fixture.coordinator.retry(taskID: created.id)
        await fixture.waitForSetup(created.id)
        #expect(fixture.record(created.id)?.setup == .started)
        #expect(fixture.taskSpaceIDs.count == 1)
    }

    @Test func aRestartMarksUnfinishedSetupFailedAndRetryContinuesFromTheJournal() async throws {
        let fixture = try Fixture()
        // The last run saved the task space's IDs and made it, then quit
        // before the agent started.
        let taskID = UUID()
        let taskSpace = TaskOperation.TaskSpace(workspaceID: UUID(), panelID: UUID())
        let windowID = try #require(fixture.store.state.selectedWindowID)
        #expect(fixture.store.send(.createTaskSpace(
            windowID: windowID,
            workspaceID: taskSpace.workspaceID,
            panelID: taskSpace.panelID,
            parentWorkspaceID: fixture.workspaceID,
            spawningSessionID: nil,
            taskID: taskID,
            title: "fix-dot",
            terminalCWD: fixture.projectRoot
        )))
        let earlierRecords = TaskRecordStore(fileURL: fixture.recordsFile)
        try earlierRecords.insert(TaskRecord(
            id: taskID,
            createdAt: Date(),
            text: "Fix the dot",
            title: "Fix the dot",
            slug: "fix-dot",
            source: .cli,
            resolved: TaskFields(workspaceID: fixture.workspaceID, agent: "codex"),
            workspaceID: fixture.workspaceID,
            projectRoot: fixture.projectRoot,
            setup: .settingUp,
            operation: TaskOperation(taskSpace: taskSpace)
        ))

        let relaunched = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        fixture.replaceCoordinator(relaunched)
        relaunched.reconcileAfterLaunch()
        guard case .setupFailed(let reason)? = fixture.record(taskID)?.setup else {
            Issue.record("unfinished setup was not marked failed")
            return
        }
        #expect(reason.contains("quit before setup finished"))

        try relaunched.retry(taskID: taskID)
        await fixture.waitForSetup(taskID)
        #expect(fixture.record(taskID)?.setup == .started)
        #expect(fixture.taskSpaceIDs == [taskSpace.workspaceID])
        #expect(fixture.router.sentTextByPanelID[taskSpace.panelID]?.contains("Fix the dot") == true)
    }

    @Test func aRestartKeepsATaskWhoseAgentAlreadyStarted() throws {
        let fixture = try Fixture()
        let records = TaskRecordStore(fileURL: fixture.recordsFile)
        let taskID = UUID()
        try records.insert(TaskRecord(
            id: taskID,
            createdAt: Date(),
            text: "x",
            title: "x",
            slug: "x",
            source: .cli,
            setup: .settingUp,
            operation: TaskOperation(
                taskSpace: .init(workspaceID: UUID(), panelID: UUID()),
                agentLaunch: .init(sessionID: "s1", at: Date())
            )
        ))
        let relaunched = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        relaunched.reconcileAfterLaunch()
        #expect(relaunched.records.record(id: taskID)?.setup == .started)
    }

    @Test func aTaskSpaceWithoutARecordGetsOneRebuilt() throws {
        let fixture = try Fixture()
        let taskID = UUID()
        let workspaceID = UUID()
        let windowID = try #require(fixture.store.state.selectedWindowID)
        _ = fixture.store.send(.setWorkspaceRootDirectory(workspaceID: fixture.workspaceID, rootDirectory: fixture.projectRoot))
        #expect(fixture.store.send(.createTaskSpace(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: UUID(),
            parentWorkspaceID: fixture.workspaceID,
            spawningSessionID: nil,
            taskID: taskID,
            title: "lost-task",
            terminalCWD: fixture.projectRoot
        )))

        fixture.coordinator.reconcileAfterLaunch()
        let rebuilt = try #require(fixture.record(taskID))
        #expect(rebuilt.source == .recovered)
        #expect(rebuilt.setup == .started)
        #expect(rebuilt.title == "lost-task")
        #expect(rebuilt.workspaceID == fixture.workspaceID)
        #expect(rebuilt.projectRoot == fixture.projectRoot)
        #expect(rebuilt.taskSpaceWorkspaceID == workspaceID)
    }

    @Test func deleteClosesAnUntouchedTaskSpaceAndRemovesTheFiles() async throws {
        let fixture = try Fixture(readinessTimeout: .milliseconds(300))
        fixture.router.defaultPromptState = .exited
        let file = fixture.root.appendingPathComponent("notes.md")
        try Data("notes".utf8).write(to: file)
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "x", files: [file.path], workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(created.id)
        #expect(fixture.taskSpaceIDs.count == 1)
        let attachmentFolder = fixture.attachmentsDirectory.appendingPathComponent(created.id.uuidString)
        #expect(FileManager.default.fileExists(atPath: attachmentFolder.path))

        try fixture.coordinator.delete(taskID: created.id)
        #expect(fixture.record(created.id) == nil)
        #expect(fixture.savedRecord(created.id) == nil)
        #expect(fixture.taskSpaceIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: attachmentFolder.path) == false)
    }

    @Test func attachmentsGoAWeekAfterTheTaskFinishesAndItsTaskSpaceCloses() async throws {
        let fixture = try Fixture()
        let file = fixture.root.appendingPathComponent("repro.png")
        try Data("png".utf8).write(to: file)
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "x", files: [file.path], workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(created.id)
        let attachmentFolder = fixture.attachmentsDirectory.appendingPathComponent(created.id.uuidString)
        let taskSpaceID = try #require(fixture.record(created.id)?.taskSpaceWorkspaceID)
        let start = Date()
        func sweep(after interval: TimeInterval) {
            fixture.clock = start.addingTimeInterval(interval)
            fixture.coordinator.removeExpiredAttachments()
        }

        fixture.clock = start
        try fixture.coordinator.markDone(taskID: created.id)
        // An open task space keeps the files, however long ago the task finished.
        sweep(after: 0)
        sweep(after: 30 * 24 * 60 * 60)
        #expect(FileManager.default.fileExists(atPath: attachmentFolder.path))
        #expect(fixture.record(created.id)?.attachmentsFinishedSeenAt == nil)

        // The week starts when the sweep sees the task finished and closed.
        _ = fixture.store.send(.closeWorkspace(workspaceID: taskSpaceID))
        sweep(after: 0)
        #expect(fixture.record(created.id)?.attachmentsFinishedSeenAt == start)
        // While tasks.toml cannot be read, nothing is removed.
        fixture.configError = TaskError("tasks.toml:3: bad value")
        sweep(after: TaskAttachmentRetention.keepAfterFinish)
        #expect(FileManager.default.fileExists(atPath: attachmentFolder.path))
        fixture.configError = nil
        sweep(after: TaskAttachmentRetention.keepAfterFinish - 60)
        #expect(FileManager.default.fileExists(atPath: attachmentFolder.path))

        sweep(after: TaskAttachmentRetention.keepAfterFinish)
        #expect(FileManager.default.fileExists(atPath: attachmentFolder.path) == false)
        fixture.coordinator.records.flushForTesting()
        // The record stays, with the files' names and when they went.
        let saved = try #require(fixture.savedRecord(created.id))
        // Saved dates keep whole seconds.
        let removedAt = try #require(saved.attachmentsRemovedAt)
        #expect(abs(removedAt.timeIntervalSince(start.addingTimeInterval(TaskAttachmentRetention.keepAfterFinish))) < 1)
        #expect(saved.attachments.map(\.displayName) == ["repro.png"])
    }

    @Test func aTaskWhoseFilesWereRemovedIsNotRetried() async throws {
        let fixture = try Fixture()
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "x", workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(created.id)
        fixture.coordinator.records.update(id: created.id) {
            $0.setup = .setupFailed(reason: "no agent")
            $0.archivedAt = Date()
            $0.attachmentsRemovedAt = Date()
        }
        #expect(throws: TaskError.self) { try fixture.coordinator.retry(taskID: created.id) }
        #expect(fixture.record(created.id)?.setup == .setupFailed(reason: "no agent"))
    }

    @Test func deleteKeepsAUsedTaskSpaceButDropsItsTaskLink() async throws {
        let fixture = try Fixture()
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "x", workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(created.id)
        let taskSpaceID = try #require(fixture.record(created.id)?.taskSpaceWorkspaceID)

        try fixture.coordinator.delete(taskID: created.id)
        #expect(fixture.taskSpaceIDs == [taskSpaceID])
        #expect(fixture.store.state.workspacesByID[taskSpaceID]?.taskID == nil)
        // No record comes back on the next launch.
        fixture.coordinator.reconcileAfterLaunch()
        #expect(fixture.coordinator.records.records.isEmpty)
    }

    @Test func requestIDsBelongToTheirCaller() async throws {
        let fixture = try Fixture()
        let request = TaskCreateRequest(text: "same key", clientRequestID: "req-1", workspaceID: fixture.workspaceID, agent: "codex")
        let fromCLI = try await fixture.coordinator.create(request)
        let fromAgent = try await fixture.coordinator.create(request, caller: TaskCaller(sessionID: "agent-1", workspaceID: fixture.workspaceID))
        #expect(fromAgent.id != fromCLI.id)
        #expect(try await fixture.coordinator.create(request, caller: TaskCaller(sessionID: "agent-1", workspaceID: fixture.workspaceID)).id == fromAgent.id)
    }

    @Test func theTextIsKeptExactlyAsWritten() async throws {
        let fixture = try Fixture()
        let text = "  Fix this:\n\n    let x = 1\n"
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: text, workspaceID: fixture.workspaceID, agent: "codex"))
        #expect(created.text == text)
        #expect(created.title == "Fix this:")
        await fixture.waitForSetup(created.id)
        let panelID = try #require(fixture.record(created.id)?.operation.taskSpace?.panelID)
        #expect(fixture.router.sentTextByPanelID[panelID]?.contains("    let x = 1") == true)
    }

    @Test func aLinkedAttachmentIsCopiedAsAFile() async throws {
        let fixture = try Fixture()
        let original = fixture.root.appendingPathComponent("original.log")
        try Data("log".utf8).write(to: original)
        let link = fixture.root.appendingPathComponent("latest.log")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "original.log")

        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "x", files: [link.path], workspaceID: fixture.workspaceID, agent: "codex"))
        try FileManager.default.removeItem(at: original)
        let copy = try #require(created.attachments.first)
        #expect(copy.displayName == "latest.log")
        let attributes = try FileManager.default.attributesOfItem(atPath: copy.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: URL(filePath: copy.path)) == Data("log".utf8))
    }

    @Test func aTaskThatCannotBeSavedMakesNothing() async throws {
        let fixture = try Fixture()
        // A file where the records folder should be: every save fails.
        let blocker = fixture.root.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let coordinator = fixture.makeCoordinator(records: TaskRecordStore(fileURL: blocker.appendingPathComponent("task-records.json")))
        fixture.replaceCoordinator(coordinator)
        let file = fixture.root.appendingPathComponent("notes.md")
        try Data("notes".utf8).write(to: file)

        do {
            try await coordinator.create(TaskCreateRequest(text: "x", files: [file.path], workspaceID: fixture.workspaceID, agent: "codex"))
            Issue.record("expected the save to fail")
        } catch {
            #expect(error.localizedDescription.contains("could not save the task"))
        }
        #expect(coordinator.records.records.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.taskSpaceIDs.isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.attachmentsDirectory.path)) ?? [] == [])
    }

    @Test func retryOffersTheCreatorANewTaskSpace() async throws {
        let fixture = try Fixture(readinessTimeout: .milliseconds(300))
        fixture.router.defaultPromptState = .exited
        let caller = TaskCaller(sessionID: "agent-1", workspaceID: fixture.workspaceID)
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "x", agent: "codex"), caller: caller)
        await fixture.waitForSetup(created.id)
        let firstSpace = try #require(fixture.record(created.id)?.taskSpaceWorkspaceID)
        #expect(fixture.store.send(.closeWorkspace(workspaceID: firstSpace)))

        fixture.router.defaultPromptState = .idleAtPrompt
        try fixture.coordinator.retry(taskID: created.id)
        await fixture.waitForSetup(created.id)
        let secondSpace = try #require(fixture.record(created.id)?.taskSpaceWorkspaceID)
        #expect(secondSpace != firstSpace)
        #expect(fixture.scopeGrants.map(\.workspaceID) == [firstSpace, secondSpace])
        #expect(fixture.scopeGrants.allSatisfy { $0.sessionID == "agent-1" })
    }

    @Test func deleteKeepsATaskSpaceWhoseAgentAlreadyExited() async throws {
        let fixture = try Fixture()
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "x", workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(created.id)
        let record = try #require(fixture.record(created.id))
        let taskSpaceID = try #require(record.taskSpaceWorkspaceID)
        fixture.sessionRuntimeStore.stopSession(sessionID: try #require(record.operation.agentLaunch?.sessionID), at: Date())

        try fixture.coordinator.delete(taskID: created.id)
        #expect(fixture.taskSpaceIDs == [taskSpaceID])
    }
}
