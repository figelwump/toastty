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

        init(startsSession: Bool = true) async throws {
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
            guard startsSession else { return }
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

    /// A dev run does not start the coordinator at launch. Opening it
    /// starts it and shows the chat, unless the run is automation.
    @Test func openingTheChatStartsACoordinatorThatThisRunDidNotStart() async throws {
        let fixture = try await Fixture(startsSession: false)
        let windowID = try #require(fixture.tasks.store.state.windows.first?.id)
        #expect(fixture.chat.show(taskID: nil) == false)
        #expect(fixture.session.workspaceID == nil)

        fixture.session.startsOnRequest = true
        #expect(fixture.chat.show(taskID: nil))
        await fixture.tasks.waitUntil("the chat shows") {
            fixture.session.workspaceID != nil
                && fixture.tasks.store.state.window(id: windowID)?.selectedWorkspaceID == fixture.session.workspaceID
        }
        #expect(fixture.tasks.store.state.showsCoordinatorChat(windowID: windowID))
        await fixture.tasks.waitUntil("the coordinator starts") { fixture.launcher.calls.count == 1 }
    }

    @Test func theTasksViewActionOpensTheChatAndThePaletteActsOnItsOpenCard() async throws {
        let fixture = try await Fixture()
        CoordinatorChatController.shared = fixture.chat
        defer { CoordinatorChatController.shared = nil }
        let task = try await fixture.taskWithPacket()
        let windowID = try #require(fixture.tasks.store.state.windows.first?.id)

        // The Tasks view's action, from scripts written before the chat.
        _ = try await fixture.executor().runActionAsync(
            id: "window.tasks.show",
            args: [:],
            context: AutomationRequestContext(callerSessionID: nil, commandName: "app_control.run_action")
        )
        #expect(fixture.tasks.store.state.showsCoordinatorChat(windowID: windowID))

        await fixture.chat.refresh()
        let selection = try #require(fixture.tasks.store.commandSelection(preferredWindowID: windowID))
        func current() -> TaskBoardCurrentTask? {
            fixture.board.currentTask(in: selection) { _ in [] }
        }
        // No card is open yet, so the palette offers no task commands.
        #expect(current() == nil)
        let card = try #require(fixture.card(forTask: task.id))
        await fixture.chat.handle(.rendered(expanded: [card.id]), from: nil)
        #expect(current()?.item.taskID == task.id)
        #expect(current()?.source == .coordinatorChat)
    }

    @Test func theComposerQueuesOnlyBehindARunningTurn() {
        func state(_ control: RemoteConversationInputControl?, reason: RemoteInputUnavailableReason = .working) -> (canSend: Bool, hint: String?) {
            let summary = RemoteConversationSummary(
                conversationID: RemoteConversationID(), provider: .claude, title: "Coordinator",
                state: reason == .starting ? .starting : .working, inputAvailability: .unavailable(reason: reason), inputControl: control,
                latestSequence: 0, updatedAt: Date(timeIntervalSince1970: 100)
            )
            return CoordinatorChatController.sendState(
                status: .running(sessionID: "s1"),
                snapshot: RemoteConversationSnapshot(summary: summary, pendingInteractions: [])
            )
        }
        let turn = RemoteInputEpoch(bindingID: UUID())
        #expect(state(RemoteConversationInputControl(turnEpoch: turn, canQueue: true)) == (true, "Sends when its turn ends"))
        // Just after a turn ends, a send would be refused: the composer waits.
        #expect(state(RemoteConversationInputControl(turnEpoch: nil, canQueue: true)) == (false, "Waiting for the coordinator's prompt"))
        // A live process can still be at a setup prompt before its first turn.
        #expect(state(RemoteConversationInputControl(turnEpoch: nil, canQueue: true), reason: .starting)
            == (false, "The coordinator is starting. Check its terminal for setup."))
        #expect(state(nil, reason: .starting).canSend == false)
        #expect(state(RemoteConversationInputControl(turnEpoch: nil, canQueue: true), reason: .unknownProviderState)
            == (false, "Waiting for the coordinator's prompt"))
        #expect(state(nil).canSend == false)
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

    @Test func reportMarksUseThePacketReplyAndRejectOtherScreenshots() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithPacket()
        let marks = [CoordinatorReportMark(shot: "after-390", note: "Move the bar up", x: 0.4, y: 0.5)]
        #expect(fixture.chat.sendReportMarks(taskID: task.id, version: 1, marks: marks) == .sent)
        #expect(fixture.typed.entries.last?.text == "Review note on packet v1: 1 marks on the screenshots:\n1. Move the bar up [after-390]")
        let count = fixture.typed.entries.count
        #expect(fixture.chat.sendReportMarks(taskID: task.id, version: 2, marks: marks) == .rejected)
        #expect(fixture.chat.sendReportMarks(taskID: task.id, version: 1, marks: [.init(shot: "missing", note: "Fix", x: 0, y: 0)]) == .rejected)
        #expect(fixture.chat.sendReportMarks(taskID: task.id, version: 1, marks: [.init(shot: "after-390", note: " ", x: 0, y: 0)]) == .rejected)
        #expect(fixture.chat.sendReportMarks(taskID: task.id, version: 1, marks: [.init(shot: "after-390", note: "Fix", x: .nan, y: 0)]) == .rejected)
        #expect(fixture.typed.entries.count == count)
        try fixture.tasks.coordinator.records.save(id: task.id) { $0.archivedAt = Date() }
        #expect(fixture.chat.sendReportMarks(taskID: task.id, version: 1, marks: marks) == .rejected)
        #expect(fixture.typed.entries.count == count)
    }

    @Test func reportBridgeRejectsNonJSONBodiesBeforeSerialization() {
        let good: [String: Any] = ["shot": "after-390", "note": "Move it", "x": 0.5, "y": 0.5]
        #expect(CoordinatorReportMark.decode([good])?.count == 1)
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            var raw = good
            raw["x"] = invalid
            #expect(CoordinatorReportMark.decode([raw]) == nil)
        }
        var raw = good
        raw["note"] = Date()
        #expect(CoordinatorReportMark.decode([raw]) == nil)
        #expect(CoordinatorReportMark.decode(Array(repeating: good, count: 101)) == nil)
        #expect(CoordinatorReportMark.message([.init(shot: "after-390", note: "\u{1b}[201~", x: 0, y: 0)], screenshotNames: ["after-390"]) == nil)
    }

    @Test(arguments: [false, true])
    func closedTasksRemainAvailableForCoordinatorQuestions(archived: Bool) async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithPacket()
        try fixture.tasks.coordinator.records.save(id: task.id) {
            if archived { $0.archivedAt = Date() }
            else { $0.doneAt = Date() }
        }
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.addresses.contains(where: { $0.kind == "task" && $0.id == task.id.uuidString }) == true)
        await fixture.chat.handle(.ask(taskID: task.id, version: 1, text: "What changed?"), token: 91, from: nil)
        // The fixture has no conversation transport. The task still passes
        // target validation, so only the coordinator's availability blocks it.
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.notice?.text == "The coordinator is not running.")
        #expect(fixture.chat.lastPayload?.ack == .init(token: 91, ok: false))
        await fixture.chat.handle(.ask(taskID: UUID(), version: nil, text: "What changed?"), token: 92, from: nil)
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.notice?.text == "That task is no longer available. Pick it again before sending.")
        #expect(fixture.chat.lastPayload?.ack == .init(token: 92, ok: false))
    }

    @Test func reportBridgeOnlyAcceptsItsOwnMainFrameRoute() {
        let id = UUID()
        let url = URL(string: "toastty://coordinator/report/\(id.uuidString)/1")!
        #expect(CoordinatorReportBridge.reportRoute(url: url, isMainFrame: true) != nil)
        #expect(CoordinatorReportBridge.reportRoute(url: url, isMainFrame: false) == nil)
        #expect(CoordinatorReportBridge.reportRoute(url: URL(string: "https://coordinator/report/\(id)/1"), isMainFrame: true) == nil)
        #expect(CoordinatorReportBridge.reportRoute(url: URL(string: "toastty://coordinator/packet-data/\(id)/1"), isMainFrame: true) == nil)
    }

    @Test func projectRequestsRoundTripWithoutConfusingTaskQuestions() throws {
        let request = CoordinatorProjectRequest(projectName: "Billing \"app\"", projectRoot: "/repos/billing", workspaceID: UUID(), text: "Fix totals\nplease")
        #expect(CoordinatorProjectRequest(message: request.message) == request)
        #expect(CoordinatorTaskAsk(message: request.message) == nil)
        #expect(CoordinatorProjectRequest(message: "Route to billing please") == nil)
        #expect(CoordinatorChatPageEvent(body: ["type": "project", "projectID": "/repos/billing", "text": "go"]) == .project(id: "/repos/billing", text: "go"))
        #expect(CoordinatorChatPageEvent(body: ["type": "project", "projectID": "", "text": "go"]) == nil)
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

    @Test func aQuestionFromACardShowsOnlyWhatTheUserTyped() {
        let taskID = UUID()
        // What the coordinator receives names the task, and reads back intact
        // even when the title has quotes and the text spans lines.
        let ask = CoordinatorTaskAsk(taskID: taskID, title: #"the "coordinator" session \ log"#, packetVersion: 2, text: "yes\nmove it")
        #expect(ask.message == #"About task "the \"coordinator\" session \\ log" (task ID \#(taskID.uuidString), packet v2): yes"# + "\nmove it")
        #expect(CoordinatorTaskAsk(message: ask.message) == ask)
        let noPacket = CoordinatorTaskAsk(taskID: taskID, title: "Fix totals", packetVersion: nil, text: "ok")
        #expect(CoordinatorTaskAsk(message: noPacket.message) == noPacket)
        // A title that looks like the end of the task line stays in the title.
        let lookalike = CoordinatorTaskAsk(
            taskID: taskID, title: #"A" (task ID BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB): B"#, packetVersion: nil, text: "ok"
        )
        #expect(CoordinatorTaskAsk(message: lookalike.message) == lookalike)
        // An older message with an unescaped quote in its title shows as sent.
        #expect(CoordinatorTaskAsk(message: "About task \"say \"hi\"\" (task ID \(taskID.uuidString)): ok") == nil)
        #expect(CoordinatorTaskAsk(message: "About task \"Fix\" (task ID not-a-uuid): ok") == nil)
        #expect(CoordinatorTaskAsk(message: "What needs me?") == nil)

        var transcript = CoordinatorChatTranscript()
        let conversation = RemoteConversationID(rawValue: UUID())
        transcript.follow(conversation)
        for (sequence, text) in [(UInt64(1), ask.message), (2, "What needs me?")] {
            transcript.apply(ConversationEvent(
                conversationID: conversation, sequence: sequence, eventID: "\(sequence)",
                timestamp: Date(timeIntervalSince1970: 1_792_800_000), provider: .claude,
                payload: .userMessage(.init(text: text))
            ))
        }
        #expect(transcript.items.map(\.text) == ["yes\nmove it", "What needs me?"])
        #expect(transcript.items.map(\.aboutTaskID) == [taskID.uuidString, nil])
        #expect(transcript.items.first?.aboutTitle == #"the "coordinator" session \ log"#)
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
