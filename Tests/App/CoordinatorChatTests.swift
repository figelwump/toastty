import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// The coordinator chat's controller, through the actions the page and the
/// CLI send: the real task coordinator, store and reducer, the fake
/// coordinator launcher, and typed text in place of terminals.
@MainActor
struct CoordinatorChatTests {
    private struct OfflineGitHub: WorkspaceMergeCommandRunning {
        func run(arguments: [String], directory: String, timeout: TimeInterval) async -> WorkspaceMergeCommandResult {
            WorkspaceMergeCommandResult(exitCode: 1, stdout: "", stderr: "offline", failure: nil)
        }
    }

    @MainActor
    final class Fixture {
        let tasks: TaskCoordinatorTests.Fixture
        let launcher = TaskStartWorkTests.FakeLauncher()
        let sessions = TaskStartWorkTests.FakeSessions()
        let session: CoordinatorSessionController
        let chat: CoordinatorChatController
        let board: TaskBoardStore
        let typed = Typed()

        @MainActor
        final class Typed {
            var entries: [(text: String, panelID: UUID)] = []
        }

        init() async throws {
            tasks = try TaskCoordinatorTests.Fixture()
            board = TaskBoardStore(
                coordinator: tasks.coordinator,
                store: tasks.store,
                sessionRuntimeStore: tasks.sessionRuntimeStore,
                pullRequests: PullRequestStateCache(runner: OfflineGitHub()),
                refreshInterval: nil,
                releaseCheckInterval: nil
            )
            tasks.coordinator.board = board
            launcher.sessions = sessions
            session = CoordinatorSessionController(
                store: tasks.store,
                launcher: launcher,
                sessions: sessions,
                configLoader: { TasksConfig() },
                files: CoordinatorFiles(directoryURL: tasks.root.appendingPathComponent("coordinator", isDirectory: true)),
                isRestorePending: { _ in false },
                homeDirectoryPath: "/Users/tester",
                relaunchDelay: .milliseconds(10),
                terminalReadinessTimeout: .milliseconds(200)
            )
            chat = CoordinatorChatController(
                store: tasks.store,
                taskCoordinator: tasks.coordinator,
                session: session,
                conversations: nil,
                sessionRuntimeStore: tasks.sessionRuntimeStore
            )
            tasks.coordinator.coordinatorSession = session
            useLiveTaskSessions()
            session.start()
            await tasks.waitUntil("the coordinator starts") { self.session.workspaceID != nil && self.launcher.calls.count == 1 }
        }

        private func useLiveTaskSessions() {
            let terminalRuntimeRegistry = TerminalRuntimeRegistry()
            tasks.coordinator.sessions = LiveTaskSessions(
                sessionRuntimeStore: tasks.sessionRuntimeStore,
                closeController: SessionCloseController(
                    store: tasks.store,
                    sessionRuntimeStore: tasks.sessionRuntimeStore,
                    focusedPanelCommandController: FocusedPanelCommandController(
                        store: tasks.store,
                        runtimeRegistry: terminalRuntimeRegistry,
                        slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
                    ),
                    terminalCloseAssessment: { _ in nil },
                    localDocumentCloseConfirmationState: { _ in nil },
                    shouldBypassConfirmation: true
                ),
                exitController: nil,
                sendText: { [typed] text, panelID in
                    typed.entries.append((text, panelID))
                    return true
                }
            )
        }

        func executor() -> AppControlExecutor {
            let terminalRuntimeRegistry = TerminalRuntimeRegistry()
            let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
            webPanelRuntimeRegistry.bind(store: tasks.store)
            return AppControlExecutor(
                store: tasks.store,
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                webPanelRuntimeRegistry: webPanelRuntimeRegistry,
                sessionRuntimeStore: tasks.sessionRuntimeStore,
                focusedPanelCommandController: FocusedPanelCommandController(
                    store: tasks.store,
                    runtimeRegistry: terminalRuntimeRegistry,
                    slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
                ),
                agentLaunchService: tasks.launcher,
                taskCoordinator: tasks.coordinator,
                reloadConfigurationAction: nil
            )
        }

        /// A started task with packet v1, one screenshot, and a packet card.
        func taskWithPacket() async throws -> TaskRecord {
            let created = try await tasks.coordinator.create(TaskCreateRequest(text: "Fix totals", workspaceID: tasks.workspaceID, agent: "codex"))
            await tasks.waitForSetup(created.id)
            let image = tasks.root.appendingPathComponent("after-390.png")
            try Data("png".utf8).write(to: image)
            let preparation = try tasks.coordinator.preparePacketPublish(
                taskID: created.id,
                packetJSON: Data(#"{"summary": "Moves the totals up", "look_at": "The bar at 390px", "not_verified": [], "screenshots": [{"name": "after-390", "pair": "after", "width": 390}]}"#.utf8),
                screenshotPaths: [image.path]
            )
            _ = try await tasks.coordinator.finishPacketPublish(preparation)
            try session.files.append(CoordinatorEvent(at: Date(), kind: .packet, taskID: created.id, text: nil, sessionID: nil))
            return try #require(tasks.record(created.id))
        }

        func card(forTask taskID: UUID) -> CoordinatorChatCardView? {
            chat.lastPayload?.items.compactMap { item -> CoordinatorChatCardView? in
                if case .card(let card) = item, card.task?.id == taskID.uuidString { return card }
                return nil
            }.last
        }
    }

    @Test func chatShowCoversTheCoordinatorTerminalAndOpensTheTasksPacket() async throws {
        let fixture = try await Fixture()
        CoordinatorChatController.shared = fixture.chat
        defer { CoordinatorChatController.shared = nil }
        let task = try await fixture.taskWithPacket()
        let executor = fixture.executor()
        let windowID = try #require(fixture.tasks.store.state.windows.first?.id)

        let shown = try await executor.runActionAsync(
            id: "coordinator.chat.show",
            args: ["taskID": .string(task.id.uuidString)],
            context: AutomationRequestContext(callerSessionID: nil, commandName: "app_control.run_action")
        )
        #expect(shown.result?["taskID"] == .string(task.id.uuidString))
        #expect(fixture.tasks.store.state.window(id: windowID)?.selectedWorkspaceID == fixture.session.workspaceID)
        #expect(fixture.tasks.store.state.showsCoordinatorChat(windowID: windowID))

        await fixture.chat.refresh()
        let payload = try #require(fixture.chat.lastPayload)
        #expect(payload.focus?.taskID == task.id.uuidString)
        let card = try #require(fixture.card(forTask: task.id))
        #expect(card.kind == "packet")
        #expect(card.task?.title == "Fix totals")
        #expect(card.task?.stageLabel == "review")
        #expect(card.task?.canReply == true)
        #expect(card.packet?.version == 1)
        #expect(card.packet?.lookAt == "The bar at 390px")
        #expect(card.packet?.screenshots.map(\.url) == ["toastty://coordinator/packet-files/\(task.id.uuidString)/v1/after-390.png"])
        // Without a running conversation, the composer says why it is off.
        #expect(payload.coordinator.canSend == false)

        // show-terminal switches the same workspace to its raw terminal.
        _ = try executor.runAction(id: "coordinator.show-terminal", args: [:], context: AutomationRequestContext(callerSessionID: nil, commandName: "app_control.run_action"))
        #expect(fixture.tasks.store.state.showsCoordinatorChat(windowID: windowID) == false)
        #expect(fixture.chat.show(taskID: nil))
        #expect(fixture.tasks.store.state.showsCoordinatorChat(windowID: windowID))

        let missing = UUID()
        await #expect(throws: AutomationSocketError.self) {
            _ = try await executor.runActionAsync(id: "coordinator.chat.show", args: ["taskID": .string(missing.uuidString)], context: AutomationRequestContext(callerSessionID: nil, commandName: "app_control.run_action"))
        }
    }

    @Test func aReplyGoesToTheTaskAsAReviewNoteAndTakesItOutOfNeedsYou() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithPacket()
        #expect(task.readyForReviewAt != nil)
        let panelID = try #require(task.operation.taskSpace?.panelID)

        await fixture.chat.handle(.reply(taskID: task.id, version: 1, text: "Use banker's rounding"), from: nil)
        #expect(fixture.typed.entries.map(\.text) == ["Review note on packet v1: Use banker's rounding"])
        #expect(fixture.typed.entries.map(\.panelID) == [panelID])
        #expect(fixture.tasks.record(task.id)?.readyForReviewAt == nil)
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.notice?.text == "Sent to \(task.slug).")

        // Asking the coordinator needs its conversation; without one it says so.
        await fixture.chat.handle(.ask(taskID: task.id, version: 1, text: "Is this safe?"), from: nil)
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.notice == .init(text: "The coordinator is not running.", isError: true, token: 2))
    }

    @Test func reportsAndRoutingOpenInTheCoordinatorsRightPanel() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithPacket()
        let workspaceID = try #require(fixture.session.workspaceID)
        func rightPanelURLs() -> [String] {
            fixture.tasks.store.state.workspacesByID[workspaceID]?.rightAuxPanel.orderedTabs.compactMap {
                if case .web(let web) = $0.panelState { return web.restorableURL ?? "local-document" }
                return nil
            } ?? []
        }

        await fixture.chat.handle(.openReport(taskID: task.id, version: 1, screenshot: "after-390"), from: nil)
        #expect(rightPanelURLs() == ["toastty://coordinator/report/\(task.id.uuidString)/1?shot=after-390"])
        // Another view of the same task's report reuses its tab.
        await fixture.chat.handle(.openReport(taskID: task.id, version: 1, screenshot: nil), from: nil)
        #expect(rightPanelURLs() == ["toastty://coordinator/report/\(task.id.uuidString)/1"])
        await fixture.chat.handle(.openURL("https://github.com/o/r/pull/12"), from: nil)
        #expect(rightPanelURLs().last == "https://github.com/o/r/pull/12")
        await fixture.chat.handle(.openRouting, from: nil)
        #expect(rightPanelURLs().count == 3)

        // The report page reads the stored packet, and only stored files.
        let report = try #require(fixture.chat.packetReportJSON(taskID: task.id, version: 1))
        let object = try #require(try JSONSerialization.jsonObject(with: report) as? [String: Any])
        #expect(object["title"] as? String == "Fix totals")
        #expect(object["lookAt"] as? String == "The bar at 390px")
        #expect(fixture.chat.packetFileURL(taskID: task.id, version: 1, fileName: "after-390.png")?.lastPathComponent == "after-390.png")
        #expect(fixture.chat.packetFileURL(taskID: task.id, version: 1, fileName: "other.png") == nil)
        #expect(fixture.chat.packetReportJSON(taskID: task.id, version: 2) == nil)
    }

    @Test func pageEventsAndPageRoutesAreCheckedBeforeTheyRun() throws {
        let taskID = UUID()
        #expect(CoordinatorChatPageEvent(body: ["type": "send", "text": "  hi  "]) == .send("hi"))
        #expect(CoordinatorChatPageEvent(body: ["type": "send", "text": "   "]) == nil)
        #expect(CoordinatorChatPageEvent(body: ["type": "reply", "taskID": taskID.uuidString, "version": 2, "text": "ok"])
            == .reply(taskID: taskID, version: 2, text: "ok"))
        #expect(CoordinatorChatPageEvent(body: ["type": "reply", "taskID": "nope", "version": 2, "text": "ok"]) == nil)
        #expect(CoordinatorChatPageEvent(body: ["type": "openURL", "url": "file:///etc/passwd"]) == nil)
        #expect(CoordinatorChatPageEvent(body: ["type": "openURL", "url": "https://example.com"]) == .openURL("https://example.com"))
        #expect(CoordinatorChatPageEvent(body: ["type": "merge"]) == nil)
        #expect(CoordinatorChatPageEvent(body: "ready") == nil)

        func route(_ string: String) -> ToasttyCoordinatorPageRoute? { URL(string: string).flatMap(ToasttyCoordinatorPageRoute.init(url:)) }
        let id = taskID.uuidString
        #expect(route("toastty://coordinator/report/\(id)/3?shot=a") == .report(taskID: taskID, version: 3))
        #expect(route("toastty://coordinator/packet-data/\(id)/3") == .packetData(taskID: taskID, version: 3))
        #expect(route("toastty://coordinator/packet-files/\(id)/v3/after-390.png") == .packetFile(taskID: taskID, version: 3, fileName: "after-390.png"))
        #expect(route("toastty://coordinator/packet-files/\(id)/v3/..%2Fpacket.json") == nil)
        #expect(route("toastty://coordinator/packet-files/\(id)/v3/packet.json") == nil)
        #expect(route("toastty://coordinator/report/not-a-task/3") == nil)
        #expect(route("toastty://coordinator/index.html") == nil)
        #expect(CoordinatorChatController.reportURL(taskID: taskID, version: 2, screenshot: "a&b") == "toastty://coordinator/report/\(id)/2")
    }

    @Test func theTranscriptFoldsToolCallsAndMarksNewSessions() {
        var transcript = CoordinatorChatTranscript()
        let first = RemoteConversationID(rawValue: UUID())
        let at = Date(timeIntervalSince1970: 1_792_800_000)
        func event(_ sequence: UInt64, _ payload: ConversationEventPayload, in conversation: RemoteConversationID) -> ConversationEvent {
            ConversationEvent(conversationID: conversation, sequence: sequence, eventID: "\(sequence)", timestamp: at, provider: .claude, payload: payload)
        }
        transcript.follow(first)
        transcript.apply(event(1, .userMessage(.init(text: "What needs me?")), in: first))
        transcript.apply(event(2, .toolStarted(.init(callID: "c1", toolName: "Bash", detail: "toastty task list")), in: first))
        transcript.apply(event(3, .toolFinished(.init(callID: "c1", outcome: .succeeded)), in: first))
        transcript.apply(event(4, .assistantMessage(.init(text: "Two tasks need you.")), in: first))
        transcript.apply(event(5, .assistantMessage(.init(text: "  ")), in: first))
        #expect(transcript.items.map(\.type) == [.message, .tool, .message])
        #expect(transcript.items[1].outcome == "succeeded")
        #expect(transcript.items.map(\.role) == ["user", nil, "assistant"])

        transcript.follow(RemoteConversationID(rawValue: UUID()))
        #expect(transcript.items.last?.text == "A new coordinator session started")
        #expect(transcript.cursor == nil)
    }

    @Test func cardsDescribeTheStageAndTheProjectsMergePolicy() {
        #expect(CoordinatorChatTaskView.label(.needsYou(.readyForReview)) == ("review", "blue"))
        #expect(CoordinatorChatTaskView.label(.running) == ("working", "amber"))
        #expect(CoordinatorChatTaskView.label(.toShip) == ("merged · to ship", "violet"))
        var record = TaskRecord(createdAt: Date(), text: "t", title: "t", slug: "t", source: .cli)
        record.projectRoot = "/Users/tester/repos/lumen"
        var config = TasksConfig()
        #expect(CoordinatorChatTaskView.mergePolicy(record: record, config: config, homeDirectoryPath: "/Users/tester")
            == "Merge sends toastty-task-merge to the task's agent, which checks the pull request first.")
        config.workspaces = [TasksConfig.Workspace(path: "~/repos/lumen", releaseTags: "v*", merge: .direct)]
        #expect(CoordinatorChatTaskView.mergePolicy(record: record, config: config, homeDirectoryPath: "/Users/tester")
            == "Merge merges right away (merge = \"direct\"). It then waits in To ship for a v* release.")
    }
}
