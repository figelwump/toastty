import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// Exercise Peek through the app stores, task-session resolver, and actual
/// conversation service. No terminal surface or native window is created.
@MainActor
struct CoordinatorPeekStoreTests {
    private struct Terminal {
        let workspaceID: UUID
        let panelID: UUID
        let sessionID: String
    }

    @MainActor
    private final class Fixture {
        let tasks: TaskCoordinatorTests.Fixture
        let terminalRuntime: TerminalRuntimeRegistry
        let paths: ToasttyRuntimePaths
        let session: CoordinatorSessionController
        let board: TaskBoardStore
        let service: ConversationService
        let peeks: CoordinatorPeekStore
        let coordinator: Terminal

        var store: AppStore { tasks.store }
        var runtime: SessionRuntimeStore { tasks.sessionRuntimeStore }

        init(sendConfirmationTimeout: Duration = .seconds(10)) throws {
            let tasks = try TaskCoordinatorTests.Fixture()
            self.tasks = tasks
            let terminalRuntime = TerminalRuntimeRegistry(
                focusCoordinator: TerminalFocusCoordinator(),
                activateApp: { Issue.record("Peek must not activate the app.") }
            )
            self.terminalRuntime = terminalRuntime
            let paths = ToasttyRuntimePaths.resolve(environment: [
                ToasttyRuntimePaths.environmentKey: tasks.root.appendingPathComponent("peek-runtime").path
            ])
            self.paths = paths
            let windowID = try #require(tasks.store.state.windows.first?.id)
            let coordinator = try Self.makeTerminal(store: tasks.store, runtime: tasks.sessionRuntimeStore,
                windowID: windowID, title: "Coordinator", cwd: tasks.projectRoot)
            self.coordinator = coordinator
            try CoordinatorSessionState(configuration: .init(), identity: .init(
                workspaceID: coordinator.workspaceID, panelID: coordinator.panelID
            )).save(to: paths.configDirectoryURL.appendingPathComponent("coordinator-session.json"))
            session = CoordinatorSessionController(store: tasks.store, launcher: tasks.launcher,
                sessionRuntimeStore: tasks.sessionRuntimeStore, runtimePaths: paths,
                terminalReadinessTimeout: .zero)

            let focusedCommands = FocusedPanelCommandController(store: tasks.store,
                runtimeRegistry: terminalRuntime, slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator(),
                shouldConfirmClose: false)
            let closes = SessionCloseController(store: tasks.store, sessionRuntimeStore: tasks.sessionRuntimeStore,
                focusedPanelCommandController: focusedCommands,
                terminalCloseAssessment: { _ in .init(requiresConfirmation: false) },
                localDocumentCloseConfirmationState: { _ in nil }, shouldBypassConfirmation: true)
            tasks.coordinator.sessions = LiveTaskSessions(sessionRuntimeStore: tasks.sessionRuntimeStore,
                closeController: closes, exitController: nil,
                sendText: { _, _ in Issue.record("Peek must not send terminal input."); return false })
            board = TaskBoardStore(coordinator: tasks.coordinator, store: tasks.store,
                sessionRuntimeStore: tasks.sessionRuntimeStore, pullRequests: PullRequestStateCache(runner: TaskBoardTests.FakeGitHub()),
                refreshInterval: nil, releaseCheckInterval: nil)
            service = ConversationService(store: tasks.store, sessionRuntimeStore: tasks.sessionRuntimeStore,
                terminalRuntimeRegistry: terminalRuntime, runtimePaths: paths,
                sendConfirmationTimeout: sendConfirmationTimeout)
            peeks = CoordinatorPeekStore(service: service, session: session, board: board,
                store: tasks.store, sessionRuntimeStore: tasks.sessionRuntimeStore)
        }

        func viewerWindow() throws -> UUID {
            let before = Set(store.state.windows.map(\.id))
            #expect(store.send(.createWindow(seed: nil, initialFrame: nil)))
            return try #require(store.state.windows.first { !before.contains($0.id) }?.id)
        }

        func terminal(_ title: String) throws -> Terminal {
            try Self.makeTerminal(store: store, runtime: runtime,
                windowID: try #require(store.state.windows.first?.id), title: title, cwd: tasks.projectRoot)
        }

        func task(_ title: String, moved: Bool = false) throws -> (record: TaskRecord, source: Terminal, current: Terminal) {
            let source = try terminal(title)
            #expect(store.send(.setWorkspaceParent(workspaceID: source.workspaceID,
                parentWorkspaceID: tasks.workspaceID, spawningSessionID: nil)))
            var operation = TaskOperation(taskSpace: .init(workspaceID: source.workspaceID, panelID: source.panelID),
                agentLaunch: .init(sessionID: source.sessionID, at: Date()))
            let current: Terminal
            if moved {
                let workspace = try #require(store.state.workspacesByID[source.workspaceID])
                let before = Set(workspace.allPanelsByID.keys)
                #expect(store.send(.splitPanel(workspaceID: source.workspaceID,
                    tabID: try #require(workspace.tabID(containingPanelID: source.panelID)),
                    panelID: source.panelID, direction: .right, profileBinding: nil, activate: false)))
                let panelID = try #require(store.state.workspacesByID[source.workspaceID]?.allPanelsByID.keys.first { !before.contains($0) })
                current = Terminal(workspaceID: source.workspaceID, panelID: panelID, sessionID: UUID().uuidString)
                Self.register(current, store: store, runtime: runtime, cwd: tasks.projectRoot + "-task")
                operation.worktreeSession = .init(workspaceID: current.workspaceID, panelID: current.panelID,
                    sessionID: current.sessionID, forked: true)
            } else {
                current = source
            }
            let record = TaskRecord(createdAt: Date(), text: title, title: title, slug: title.lowercased().replacingOccurrences(of: " ", with: "-"),
                source: .cli, resolved: .init(workspaceID: tasks.workspaceID, agent: "claude"),
                workspaceID: tasks.workspaceID, projectRoot: tasks.projectRoot, setup: .started, operation: operation)
            try tasks.coordinator.records.insert(record)
            #expect(store.send(.setWorkspaceTaskID(workspaceID: source.workspaceID, taskID: record.id)))
            return (record, source, current)
        }

        @discardableResult
        func replaceSession(in terminal: Terminal) -> Terminal {
            let restored = Terminal(workspaceID: terminal.workspaceID, panelID: terminal.panelID, sessionID: UUID().uuidString)
            Self.register(restored, store: store, runtime: runtime, cwd: tasks.projectRoot)
            return restored
        }

        func conversationID(_ panelID: UUID) throws -> RemoteConversationID {
            try #require(service.conversationID(for: panelID))
        }

        /// Establish current-launch ownership once. Navigation assertions only
        /// read the model, so they cannot restore readiness that the app lost.
        func confirmCurrentLaunchPrompt(for model: CoordinatorConversationModel, in terminal: Terminal) throws -> RemoteInputEpoch {
            let active = try #require(runtime.sessionRegistry.activeSession(for: terminal.panelID))
            try #require(active.sessionID == terminal.sessionID)
            let now = Date()
            let transcripts = tasks.root.appendingPathComponent("peek-transcripts", isDirectory: true)
            try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
            let nativeID = UUID().uuidString
            let transcript = transcripts.appendingPathComponent("\(nativeID).jsonl")
            try Data().write(to: transcript)
            let resume = ManagedAgentResumeRecord(agent: active.agent, nativeSessionID: nativeID,
                sessionFilePath: transcript.path, cwd: try #require(active.cwd), capturedAt: now)
            runtime.updateStatus(sessionID: terminal.sessionID,
                status: SessionStatus(kind: .ready, summary: "Ready"), at: now)
            try #require(runtime.confirmNativeSessionBinding(managedSessionID: terminal.sessionID,
                panelID: terminal.panelID, record: resume))
            try #require(store.send(.updateTerminalPanelResumeRecord(panelID: terminal.panelID, resumeRecord: resume)))
            service.syncConversations()
            model.refresh()
            let epoch = try #require(model.inputEpoch)
            let id = try conversationID(terminal.panelID)
            try #require(epoch.bindingID == service.projectionStore.projectorState(for: id)?.bindingID)
            return epoch
        }

        private static func makeTerminal(store: AppStore, runtime: SessionRuntimeStore,
            windowID: UUID, title: String, cwd: String) throws -> Terminal {
            let before = Set(store.state.workspacesByID.keys)
            #expect(store.send(.createWorkspace(windowID: windowID, title: title, activate: false)))
            let workspace = try #require(store.state.workspacesByID.values.first { !before.contains($0.id) })
            let terminal = Terminal(workspaceID: workspace.id, panelID: try #require(workspace.focusedPanelID),
                sessionID: UUID().uuidString)
            register(terminal, store: store, runtime: runtime, cwd: cwd)
            return terminal
        }

        private static func register(_ terminal: Terminal, store: AppStore, runtime: SessionRuntimeStore, cwd: String) {
            let windowID = store.state.windows.first { $0.workspaceIDs.contains(terminal.workspaceID) }!.id
            runtime.startSession(sessionID: terminal.sessionID, agent: .claude, panelID: terminal.panelID,
                windowID: windowID, workspaceID: terminal.workspaceID,
                codexStatusTrackingSource: .externallyReported, cwd: cwd, repoRoot: cwd, at: Date())
        }
    }

    @Test
    func closingOneWindowPeekKeepsCoordinatorAndOtherConversationLive() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        #expect(f.service.localPanelIDs == [f.coordinator.panelID])
        let first = try f.task("First")
        let second = try f.task("Second")
        let firstWindow = try f.viewerWindow()
        let secondWindow = try f.viewerWindow()
        f.peeks.openTask(first.record.id, in: firstWindow)
        f.peeks.openTask(second.record.id, in: secondWindow)
        let coordinatorID = try f.conversationID(f.coordinator.panelID)
        let firstID = try f.conversationID(first.current.panelID)
        let secondID = try f.conversationID(second.current.panelID)
        #expect(f.service.localConversations.count == 3)

        f.peeks.close(in: firstWindow)

        #expect(f.peeks.inspections[firstWindow] == nil)
        #expect(f.peeks.inspections[secondWindow]?.panelID == second.current.panelID)
        #expect(f.service.localSnapshot(for: firstID, at: Date()) == nil)
        #expect(f.service.localSnapshot(for: coordinatorID, at: Date())?.summary.placement.panelID == f.coordinator.panelID)
        #expect(f.service.localSnapshot(for: secondID, at: Date())?.summary.placement.panelID == second.current.panelID)
        #expect(Set(f.service.localConversations.compactMap(\.placement.panelID)) == [f.coordinator.panelID, second.current.panelID])
    }

    @Test
    func twoWindowsInspectingOnePanelShareDraftAndReopeningKeepsModel() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let task = try f.task("Shared")
        let firstWindow = try f.viewerWindow()
        let secondWindow = try f.viewerWindow()
        f.peeks.openTask(task.record.id, in: firstWindow)
        let first = try #require(f.peeks.inspections[firstWindow]?.conversation)
        first.draft = "Keep this unfinished feedback"
        f.peeks.openTask(task.record.id, in: secondWindow)
        f.peeks.openTask(task.record.id, in: firstWindow)
        let second = try #require(f.peeks.inspections[secondWindow]?.conversation)
        #expect(first === second)
        #expect(f.peeks.inspections[firstWindow]?.conversation === first)
        #expect(second.draft == "Keep this unfinished feedback")

        f.peeks.close(in: firstWindow)
        f.peeks.openTask(task.record.id, in: firstWindow)
        #expect(f.peeks.inspections[firstWindow]?.conversation === second)
        #expect(f.peeks.inspections[firstWindow]?.conversation?.draft == second.draft)
        #expect(f.service.localConversations.filter { $0.placement.panelID == task.current.panelID }.count == 1)
    }

    @Test
    func taskPeekUsesCurrentWorktreeSessionWithoutChangingWindowSelection() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let task = try f.task("Moved", moved: true)
        let unrelated = try f.terminal("Unrelated")
        let viewer = try f.viewerWindow()
        let before = f.store.state.selectedWorkspaceSelection()
        #expect(f.runtime.sessionRegistry.activeSession(for: task.source.panelID)?.sessionID == task.source.sessionID)
        #expect(f.runtime.sessionRegistry.activeSession(for: unrelated.panelID)?.sessionID == unrelated.sessionID)

        f.peeks.openTask(task.record.id, in: viewer)

        let inspection = try #require(f.peeks.inspections[viewer])
        #expect(inspection.workspaceID == task.current.workspaceID)
        #expect(inspection.panelID == task.current.panelID)
        #expect(inspection.conversation?.snapshot?.summary.placement.panelID == task.current.panelID)
        #expect(f.service.activeSessionIDByConversationID[try f.conversationID(task.current.panelID)] == task.current.sessionID)
        #expect(f.service.conversationID(for: task.source.panelID) == nil)
        #expect(f.service.conversationID(for: unrelated.panelID) == nil)
        let after = f.store.state.selectedWorkspaceSelection()
        #expect(before?.windowID == after?.windowID)
        #expect(before?.workspaceID == after?.workspaceID)
        #expect(before?.workspace.focusedPanelID == after?.workspace.focusedPanelID)
    }

    @Test
    func taskPeekFollowsNativeRestoreWhileExactOldSessionLinkIsRejected() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let task = try f.task("Restored", moved: true)
        let restored = f.replaceSession(in: task.current)
        let taskWindow = try f.viewerWindow()
        let sessionWindow = try f.viewerWindow()

        f.peeks.openTask(task.record.id, in: taskWindow)
        let inspection = try #require(f.peeks.inspections[taskWindow])
        #expect(inspection.panelID == restored.panelID)
        #expect(inspection.unavailableReason == nil)
        #expect(f.service.activeSessionIDByConversationID[try f.conversationID(restored.panelID)] == restored.sessionID)

        f.peeks.openSession(task.current.sessionID, in: sessionWindow)
        #expect(f.peeks.inspections[sessionWindow]?.conversation == nil)
        #expect(f.peeks.inspections[sessionWindow]?.panelID == nil)
        #expect(f.peeks.inspections[sessionWindow]?.unavailableReason != nil)
        #expect(f.peeks.inspections[taskWindow]?.conversation === inspection.conversation)
        #expect(f.service.localSnapshot(for: try f.conversationID(restored.panelID), at: Date()) != nil)
    }

    @Test
    func closingNativeViewerWindowDropsOnlyItsInspection() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let first = try f.task("Window one")
        let second = try f.task("Window two")
        let firstWindow = try f.viewerWindow()
        let secondWindow = try f.viewerWindow()
        f.peeks.openTask(first.record.id, in: firstWindow)
        f.peeks.openTask(second.record.id, in: secondWindow)
        let secondModel = try #require(f.peeks.inspections[secondWindow]?.conversation)
        secondModel.draft = "Still here"
        let secondID = try f.conversationID(second.current.panelID)

        #expect(f.store.send(.closeWindow(windowID: firstWindow)))

        #expect(f.peeks.inspections[firstWindow] == nil)
        #expect(f.peeks.inspections[secondWindow]?.conversation === secondModel)
        #expect(secondModel.draft == "Still here")
        #expect(f.service.localSnapshot(for: secondID, at: Date())?.summary.placement.panelID == second.current.panelID)
        #expect(Set(f.service.localConversations.compactMap(\.placement.panelID)) == [f.coordinator.panelID, second.current.panelID])
    }

    @Test(arguments: [false, true])
    func openExactSessionPeekBecomesUnavailableWhenThatSessionIsReplacedAndKeepsDraft(whileHidden: Bool) async throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let task = try f.task("Pinned session")
        let viewer = try f.viewerWindow()
        f.peeks.openSession(task.current.sessionID, in: viewer)
        let model = try #require(f.peeks.inspections[viewer]?.conversation)
        let conversationID = try f.conversationID(task.current.panelID)
        let originalBinding = try f.confirmCurrentLaunchPrompt(for: model, in: task.current).bindingID
        model.draft = "Feedback for the original session"
        if whileHidden { f.peeks.close(in: viewer) }

        let replacement = f.replaceSession(in: task.current)
        await f.tasks.waitUntil("hidden draft observes the replacement session", timeout: .seconds(2)) {
            f.service.activeSessionIDByConversationID[conversationID] == replacement.sessionID
        }
        if !whileHidden {
            await f.tasks.waitUntil("exact session Peek is invalidated", timeout: .seconds(2)) {
                f.peeks.inspections[viewer]?.panelID == nil
            }
            #expect(f.peeks.inspections[viewer]?.conversation === model)
        }
        f.peeks.openTask(task.record.id, in: viewer)
        #expect(f.peeks.inspections[viewer]?.conversation === model)
        #expect(try f.confirmCurrentLaunchPrompt(for: model, in: replacement).bindingID != originalBinding)
        #expect(model.hasDraftFromPreviousSession)
        #expect(!model.canSend)
        f.peeks.openSession(task.current.sessionID, in: viewer)

        let inspection = try #require(f.peeks.inspections[viewer])
        #expect(inspection.panelID == nil)
        #expect(model.draft == "Feedback for the original session")
        #expect(f.runtime.sessionRegistry.activeSession(for: replacement.panelID)?.sessionID == replacement.sessionID)
        #expect(f.service.localPanelIDs == [f.coordinator.panelID])
        #expect(f.service.localSnapshot(for: conversationID, at: Date()) != nil)
        #expect(f.service.localConversations.allSatisfy { $0.placement.panelID != replacement.panelID })
    }

    @Test
    func movingTaskDoesNotSilentlyRetargetOpenPeekAndKeepsItsDraftForInspection() async throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let task = try f.task("Moving task")
        let viewer = try f.viewerWindow()
        f.peeks.openTask(task.record.id, in: viewer)
        let model = try #require(f.peeks.inspections[viewer]?.conversation)
        model.draft = "Finish reading this before sending"
        let destination = try f.terminal("Worktree destination")

        try f.tasks.coordinator.records.save(id: task.record.id) {
            $0.operation.worktreeSession = .init(workspaceID: destination.workspaceID,
                panelID: destination.panelID, sessionID: destination.sessionID, forked: true)
        }
        await f.tasks.waitUntil("the moved task Peek is invalidated", timeout: .seconds(2)) {
            f.peeks.inspections[viewer]?.unavailableReason != nil
        }

        let inspection = try #require(f.peeks.inspections[viewer])
        #expect(inspection.panelID == nil)
        #expect(inspection.conversation === model)
        #expect(model.draft == "Finish reading this before sending")
        #expect(f.service.localPanelIDs == [f.coordinator.panelID])
        #expect(f.service.conversationID(for: destination.panelID) == nil)

        f.peeks.openTask(task.record.id, in: viewer)
        #expect(f.peeks.inspections[viewer]?.panelID == destination.panelID)
        #expect(f.peeks.inspections[viewer]?.unavailableReason == nil)
        #expect(f.service.activeSessionIDByConversationID[try f.conversationID(destination.panelID)] == destination.sessionID)
    }

    @Test(arguments: [false, true])
    func closingStoppedTaskTerminalOrWorkspaceInvalidatesPeekWithViewerWindowOpen(closeWorkspace: Bool) async throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let task = try f.task("Stopped task")
        let viewer = try f.viewerWindow()
        f.runtime.stopSession(sessionID: task.current.sessionID, at: Date())
        // Leave another plain tab so the panel-only variant preserves the workspace.
        #expect(f.store.send(.createBackgroundTerminalTab(workspaceID: task.current.workspaceID,
            tabID: UUID(), panelID: UUID(), terminalCWD: f.tasks.projectRoot)))
        f.peeks.openTask(task.record.id, in: viewer)
        let model = try #require(f.peeks.inspections[viewer]?.conversation)
        model.draft = "Keep after terminal closes"
        let windows = Set(f.store.state.windows.map(\.id))

        if closeWorkspace {
            #expect(f.store.send(.closeWorkspace(workspaceID: task.current.workspaceID)))
        } else {
            #expect(f.store.send(.closePanel(panelID: task.current.panelID)))
        }
        await f.tasks.waitUntil("Peek observes closed terminal", timeout: .seconds(2)) {
            f.peeks.inspections[viewer]?.unavailableReason != nil
        }

        #expect(Set(f.store.state.windows.map(\.id)) == windows)
        #expect(f.peeks.inspections[viewer]?.panelID == nil)
        #expect(f.peeks.inspections[viewer]?.conversation === model)
        #expect(model.draft == "Keep after terminal closes")
        #expect(f.service.localPanelIDs == [f.coordinator.panelID])
        #expect(f.service.conversationID(for: task.current.panelID) == nil)
    }

    @Test
    func taskRemovedInvalidatesItsPeekWithoutClaimingReviewContents() async throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let task = try f.task("Removed task")
        let viewer = try f.viewerWindow()
        f.peeks.openTask(task.record.id, in: viewer)
        let model = try #require(f.peeks.inspections[viewer]?.conversation)
        model.draft = "Retain deleted task feedback"
        try f.tasks.coordinator.records.remove(id: task.record.id)
        await f.tasks.waitUntil("Peek observes removed record", timeout: .seconds(2)) {
            f.peeks.inspections[viewer]?.unavailableReason != nil
        }
        #expect(f.peeks.inspections[viewer]?.panelID == nil)
        #expect(f.peeks.inspections[viewer]?.conversation === model)
        #expect(f.service.localPanelIDs == [f.coordinator.panelID])
    }

    @Test
    func coordinatorSessionCannotCreateSecondComposer() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let viewer = try f.viewerWindow()
        f.peeks.openSession(f.coordinator.sessionID, in: viewer)
        #expect(f.peeks.inspections[viewer]?.unavailableReason != nil)
        #expect(f.peeks.inspections[viewer]?.conversation == nil)
        #expect(f.peeks.inspections[viewer]?.panelID == nil)
        #expect(f.service.localPanelIDs == [f.coordinator.panelID])
        f.peeks.close(in: viewer)
        #expect(f.service.localPanelIDs == [f.coordinator.panelID])
    }

    @Test
    func backSwitchUnavailableOpenAndReopenRetainDraftsAndFilesWithoutAnotherWindow() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let first = try f.task("First retained")
        let second = try f.task("Second retained")
        let viewer = try f.viewerWindow()
        let windows = Set(f.store.state.windows.map(\.id))
        f.peeks.openTask(first.record.id, in: viewer)
        #expect(f.service.localPanelIDs == [f.coordinator.panelID, first.current.panelID])
        let firstModel = try #require(f.peeks.inspections[viewer]?.conversation)
        let firstBinding = try f.confirmCurrentLaunchPrompt(for: firstModel, in: first.current).bindingID
        firstModel.draft = "First unfinished reply"
        let file = RemoteMessageAttachment(filename: "evidence.txt", data: Data("details".utf8))
        firstModel.attachments = [file]
        #expect(firstModel.canSend)

        f.peeks.close(in: viewer)
        #expect(f.service.localPanelIDs == [f.coordinator.panelID])
        f.peeks.openTask(first.record.id, in: viewer)
        #expect(f.service.localPanelIDs == [f.coordinator.panelID, first.current.panelID])
        #expect(f.peeks.inspections[viewer]?.conversation === firstModel)
        #expect(firstModel.inputEpoch?.bindingID == firstBinding)
        #expect(!firstModel.hasDraftFromPreviousSession)
        #expect(firstModel.canSend)
        f.peeks.openTask(second.record.id, in: viewer)
        #expect(f.service.localPanelIDs == [f.coordinator.panelID, second.current.panelID])
        let secondModel = try #require(f.peeks.inspections[viewer]?.conversation)
        let secondBinding = try f.confirmCurrentLaunchPrompt(for: secondModel, in: second.current).bindingID
        let secondFile = RemoteMessageAttachment(filename: "second.txt", data: Data("file only".utf8))
        secondModel.attachments = [secondFile]
        #expect(secondModel.canSend)
        f.peeks.openTask(UUID(), in: viewer)
        #expect(f.peeks.inspections[viewer]?.unavailableReason != nil)

        f.peeks.openTask(first.record.id, in: viewer)
        #expect(f.service.localPanelIDs == [f.coordinator.panelID, first.current.panelID])
        #expect(f.peeks.inspections[viewer]?.conversation === firstModel)
        #expect(firstModel.draft == "First unfinished reply")
        #expect(firstModel.attachments == [file])
        #expect(firstModel.inputEpoch?.bindingID == firstBinding)
        #expect(!firstModel.hasDraftFromPreviousSession)
        #expect(firstModel.canSend)
        f.peeks.openTask(second.record.id, in: viewer)
        #expect(f.service.localPanelIDs == [f.coordinator.panelID, second.current.panelID])
        #expect(f.peeks.inspections[viewer]?.conversation === secondModel)
        #expect(secondModel.attachments == [secondFile])
        #expect(secondModel.inputEpoch?.bindingID == secondBinding)
        #expect(!secondModel.hasDraftFromPreviousSession)
        #expect(secondModel.canSend)
        #expect(Set(f.store.state.windows.map(\.id)) == windows)
        #expect(Set(f.peeks.inspections.keys) == [viewer])
    }

    @Test
    func invalidatedSessionModelIsReusedByTaskPeekAcrossWindows() async throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let task = try f.task("Retained old session")
        let exactWindow = try f.viewerWindow()
        let taskWindow = try f.viewerWindow()
        f.peeks.openSession(task.current.sessionID, in: exactWindow)
        let model = try #require(f.peeks.inspections[exactWindow]?.conversation)
        model.draft = "Unsent before restore"
        f.peeks.openTask(task.record.id, in: taskWindow)
        #expect(f.peeks.inspections[taskWindow]?.conversation === model)

        let restored = f.replaceSession(in: task.current)
        await f.tasks.waitUntil("exact link stays pinned after restore", timeout: .seconds(2)) {
            f.peeks.inspections[exactWindow]?.unavailableReason != nil
        }
        #expect(f.peeks.inspections[exactWindow]?.conversation === model)
        #expect(f.peeks.inspections[taskWindow]?.panelID == restored.panelID)
        #expect(f.peeks.inspections[taskWindow]?.unavailableReason == nil)
        #expect(f.service.localPanelIDs == [f.coordinator.panelID, restored.panelID])

        f.peeks.close(in: taskWindow)
        f.peeks.openSession(task.current.sessionID, in: exactWindow)
        #expect(f.peeks.inspections[exactWindow]?.conversation === model)
        #expect(f.peeks.inspections[exactWindow]?.panelID == nil)
        f.peeks.openTask(task.record.id, in: taskWindow)
        #expect(f.peeks.inspections[taskWindow]?.conversation === model)
        #expect(model.draft == "Unsent before restore")
    }

    @Test
    func savedFallbackCannotAttachToDifferentActiveSession() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let task = try f.task("Unavailable task resolver")
        let viewer = try f.viewerWindow()
        _ = f.replaceSession(in: task.current)
        // No live task resolver is available during this fallback path.
        f.tasks.coordinator.sessions = nil
        f.peeks.openTask(task.record.id, in: viewer)
        #expect(f.peeks.inspections[viewer]?.panelID == nil)
        #expect(f.peeks.inspections[viewer]?.conversation == nil)
        #expect(f.peeks.inspections[viewer]?.unavailableReason != nil)
        #expect(f.service.localPanelIDs == [f.coordinator.panelID])
    }

    @Test
    func registryFallbackUsesWorkspaceAndPanelFromSameRecord() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let task = try f.task("Registry fallback")
        let destination = try f.terminal("Separate workspace")
        try f.tasks.coordinator.records.save(id: task.record.id) {
            $0.operation.agentLaunch = .init(sessionID: destination.sessionID, at: Date())
        }
        f.tasks.coordinator.sessions = nil
        let viewer = try f.viewerWindow()
        f.peeks.openTask(task.record.id, in: viewer)
        #expect(f.peeks.inspections[viewer]?.panelID == destination.panelID)
        #expect(f.peeks.inspections[viewer]?.workspaceID == destination.workspaceID)
        #expect(f.peeks.inspections[viewer]?.unavailableReason == nil)
    }

    @Test(arguments: [false, true])
    func movingTerminalBetweenWorkspacesKeepsPeekOnSamePanel(whileHidden: Bool) async throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let task = try f.task("Moved panel")
        let destination = try f.terminal("Other workspace")
        let viewer = try f.viewerWindow()
        f.peeks.openTask(task.record.id, in: viewer)
        let model = try #require(f.peeks.inspections[viewer]?.conversation)
        let binding = try f.confirmCurrentLaunchPrompt(for: model, in: task.current).bindingID
        model.draft = "Same panel"
        if whileHidden { f.peeks.close(in: viewer) }
        #expect(f.store.send(.movePanelToWorkspace(panelID: task.current.panelID,
            targetWorkspaceID: destination.workspaceID, targetSlotID: nil)))
        if whileHidden { f.peeks.openTask(task.record.id, in: viewer) }
        await f.tasks.waitUntil("Peek follows panel location", timeout: .seconds(2)) {
            f.peeks.inspections[viewer]?.workspaceID == destination.workspaceID
        }
        #expect(f.peeks.inspections[viewer]?.panelID == task.current.panelID)
        #expect(f.peeks.inspections[viewer]?.conversation === model)
        #expect(f.peeks.inspections[viewer]?.unavailableReason == nil)
        #expect(model.inputEpoch?.bindingID == binding)
        #expect(!model.hasDraftFromPreviousSession)
        #expect(model.canSend)
    }

    @Test
    func hidingDuringAcceptedSendClearsDraftAndReleasesObservationAfterConfirmationExpires() async throws {
        let f = try Fixture(sendConfirmationTimeout: .milliseconds(40))
        defer {
            f.terminalRuntime.setAutomationSendTextHandlerForTesting(nil)
            f.service.setLocalPanelIDs([])
        }
        let task = try f.task("Hide during delivery")
        let viewer = try f.viewerWindow()
        f.peeks.openTask(task.record.id, in: viewer)
        let model = try #require(f.peeks.inspections[viewer]?.conversation)
        let id = try f.conversationID(task.current.panelID)
        let binding = try f.confirmCurrentLaunchPrompt(for: model, in: task.current).bindingID
        model.draft = "Deliver once while leaving Peek"
        var delivered: [String] = []
        f.terminalRuntime.setAutomationPromptStateHandlerForTesting { _ in .idleAtPrompt }
        f.terminalRuntime.setAutomationSendTextHandlerForTesting { text, _, panelID, _ in
            #expect(panelID == task.current.panelID)
            #expect(model.sending)
            delivered.append(text)
            // Use the real service result, with navigation at the terminal
            // delivery boundary while the model still owns this send.
            f.peeks.close(in: viewer)
            #expect(f.service.localPanelIDs == [f.coordinator.panelID])
            #expect(model.inputEpoch?.bindingID == binding)
            return true
        }
        await model.send()
        #expect(delivered == ["Deliver once while leaving Peek"])
        #expect(model.draft.isEmpty)
        #expect(!model.sending)
        #expect(model.notice == nil)
        #expect(model.draftHold == nil)
        await f.tasks.waitUntil("send completion releases hidden draft observation", timeout: .seconds(2)) {
            f.service.localSnapshot(for: id, at: Date()) == nil
        }
        #expect(f.service.conversationID(for: f.coordinator.panelID) != nil)
        f.peeks.openTask(task.record.id, in: viewer)
        #expect(f.peeks.inspections[viewer]?.conversation !== model)
    }

    @Test
    func clearingHiddenDraftAndAttachmentsReleasesObservationAndEvictsModel() async throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let task = try f.task("Clear hidden draft")
        let viewer = try f.viewerWindow()
        f.peeks.openTask(task.record.id, in: viewer)
        let model = try #require(f.peeks.inspections[viewer]?.conversation)
        let id = try f.conversationID(task.current.panelID)
        let binding = try f.confirmCurrentLaunchPrompt(for: model, in: task.current).bindingID
        model.draft = "Unfinished reply"
        model.attachments = [RemoteMessageAttachment(filename: "note.txt", data: Data("note".utf8))]
        f.peeks.close(in: viewer)
        #expect(f.service.localSnapshot(for: id, at: Date()) != nil)
        model.draft = ""
        // A remaining attachment must keep the same binding.
        await Task.yield()
        #expect(model.inputEpoch?.bindingID == binding)
        model.attachments = []
        await f.tasks.waitUntil("empty hidden draft releases observation", timeout: .seconds(2)) {
            f.service.localSnapshot(for: id, at: Date()) == nil
        }
        f.peeks.openTask(task.record.id, in: viewer)
        #expect(f.peeks.inspections[viewer]?.conversation !== model)
    }

    @Test
    func emptyDormantModelsCanBeEvicted() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let task = try f.task("Empty draft")
        let viewer = try f.viewerWindow()
        f.peeks.openTask(task.record.id, in: viewer)
        let first = try #require(f.peeks.inspections[viewer]?.conversation)
        f.peeks.close(in: viewer)
        f.peeks.openTask(task.record.id, in: viewer)
        let reopened = try #require(f.peeks.inspections[viewer]?.conversation)
        #expect(first !== reopened)
        #expect(reopened.draft.isEmpty)
    }
}
