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
    @Test func routeEnvelopesAreStrictAndKeepQuotedMultilineQuestions() throws {
        let answer = CoordinatorRouteAnswer(questionID: UUID(), replyID: UUID(),
            question: "Which project is \"dark mode\" for?\nBoth have settings.", answer: "/repos/app")
        #expect(CoordinatorRouteAnswer(message: answer.message) == answer)
        #expect(CoordinatorTaskAsk(message: answer.message) == nil)
        let task = CoordinatorTaskAsk(taskID: UUID(), title: "t", packetVersion: nil, text: "yes")
        #expect(CoordinatorRouteAnswer(message: task.message) == nil)
        for invalid in ["prefix " + answer.message, String(answer.message.dropLast()),
                        answer.message.replacingOccurrences(of: "\"answer\":", with: "\"extra\":1,\"answer\":"),
                        "Coordinator route answer: {}"] {
            #expect(CoordinatorRouteAnswer(message: invalid) == nil)
        }
        let oversized = CoordinatorRouteAnswer(questionID: UUID(), replyID: UUID(),
            question: String(repeating: "🧭", count: CoordinatorEvent.maximumTextLength),
            answer: String(repeating: "🧭", count: CoordinatorEvent.maximumOptionLength))
        #expect(oversized.message.utf8.count > CoordinatorChatPageEvent.maximumTextLength)
        #expect(CoordinatorRouteAnswer(message: oversized.message) == nil)
        #expect(CoordinatorChatPageEvent(body: ["type": "answerRoute", "questionID": answer.questionID.uuidString, "optionIndex": 1])
                == .answerRoute(questionID: answer.questionID, optionIndex: 1))
        for index in [-1, 6, 0.5, true, "0"] as [Any] {
            #expect(CoordinatorChatPageEvent(body: ["type": "answerRoute", "questionID": answer.questionID.uuidString, "optionIndex": index]) == nil)
        }
    }

    @Test func routeDeliverySurvivesRelaunchAndAcceptedEchoWins() throws {
        let question = CoordinatorEvent(at: Date(), kind: .question, taskID: nil, text: "Which project?", sessionID: nil,
                                        options: ["/repos/app", "/repos/site"])
        let answer = CoordinatorRouteAnswer(questionID: question.id, replyID: UUID(), question: question.text!, answer: "/repos/app")
        let pending = CoordinatorChatController.routeReply(answer, at: Date(), delivery: .pending)
        let rejected = CoordinatorChatController.routeReply(answer, at: Date(), delivery: .rejected)
        let accepted = CoordinatorChatController.routeReply(answer, at: Date(), delivery: .accepted)
        var events = [question, pending]
        #expect(!CoordinatorChatController.canAnswerRoute(questionID: question.id, in: events))
        // Re-read the actual on-disk format used by a new controller.
        let log = try events.reduce(into: Data()) { data, event in data.append(try event.jsonLine()); data.append(10) }
        #expect(!CoordinatorChatController.canAnswerRoute(questionID: question.id, in: CoordinatorEvent.decodeLog(log)))
        events.append(rejected)
        #expect(CoordinatorChatController.canAnswerRoute(questionID: question.id, in: events))
        #expect(CoordinatorChatController.canAnswerRoute(questionID: question.id, in: [question, rejected, pending]))
        events += [accepted, rejected, pending]
        #expect(!CoordinatorChatController.canAnswerRoute(questionID: question.id, in: events))
        let card = try #require(CoordinatorChatTimeline.cards(events: events, packets: [:]).first)
        #expect(card.answer == answer.answer && !card.answerPending)
    }

    @Test func routeChoicesRejectTaskQuestionsAndInvalidIndexesAndAllowRetryAfterRefusal() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithoutPacket()
        let scoped = CoordinatorEvent(at: Date(), kind: .question, taskID: task.id, text: "Which base?", sessionID: nil, options: ["main"])
        let route = CoordinatorEvent(at: Date(), kind: .question, taskID: nil, text: "Which project?", sessionID: nil,
                                     options: ["/repos/app", "/repos/site"])
        try fixture.session.files.append(scoped)
        try fixture.session.files.append(route)
        await fixture.chat.handle(.answerRoute(questionID: scoped.id, optionIndex: 0), from: nil)
        await fixture.chat.handle(.answerRoute(questionID: route.id, optionIndex: 8), from: nil)
        #expect(fixture.session.files.events().filter { $0.kind == .reply }.isEmpty)
        // This fixture has no coordinator input surface, so delivery fails.
        await fixture.chat.handle(.answerRoute(questionID: route.id, optionIndex: 0), token: 8, from: nil)
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.ack == .init(token: 8, ok: false))
        #expect(CoordinatorChatController.canAnswerRoute(questionID: route.id, in: fixture.session.files.events()))
        #expect(fixture.typed.entries.isEmpty)
    }

    @Test func aFailedAgentGetsACardWithoutACoordinatorPost() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithoutPacket()
        let sessionID = try #require(task.operation.agentLaunch?.sessionID)
        fixture.tasks.sessionRuntimeStore.updateStatus(sessionID: sessionID,
            status: SessionStatus(kind: .error, summary: "Error", detail: "The command failed with exit code 1."), at: Date())
        await fixture.chat.refresh()
        let card = try #require(fixture.card(forTask: task.id))
        #expect(card.task?.stageLabel == "stuck")
        #expect(card.task?.failureText == "The command failed with exit code 1.")
        #expect(card.task?.canArchive == true && card.task?.hasTaskSpace == true)
        #expect(card.isCurrent)
        #expect(fixture.chat.hasCards(taskID: task.id))
        await fixture.chat.handle(.taskAction(rowID: task.id.uuidString, actionID: "open"), from: nil)
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.focus?.taskID == task.id.uuidString)
        // A retained draft still belongs to the task after recovery replaces
        // the card that was introduced by its error status.
        try fixture.session.files.append(CoordinatorEvent(at: Date(), kind: .taskStarted,
            taskID: task.id, text: nil, sessionID: nil))
        fixture.tasks.sessionRuntimeStore.updateStatus(sessionID: sessionID,
            status: SessionStatus(kind: .ready, summary: "Recovered"), at: Date())
        await fixture.chat.refresh()
        #expect(fixture.card(forTask: task.id)?.id != card.id)
        await fixture.chat.handle(.reply(taskID: task.id, version: nil, text: "Keep the error-card draft",
                                        cardID: card.id), token: 75, from: nil)
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.ack == .init(token: 75, ok: true))
        #expect(fixture.typed.entries.last?.text.contains("Keep the error-card draft") == true)
    }
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

        func taskWithoutPacket() async throws -> TaskRecord {
            let created = try await tasks.coordinator.create(TaskCreateRequest(
                text: "Keep the coupon visible", workspaceID: tasks.workspaceID, agent: "codex"
            ))
            await tasks.waitForSetup(created.id)
            return try #require(tasks.record(created.id))
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

    @Test func aQuestionAnswerNeedsNoPacketAndSurvivesANewChatController() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithoutPacket()
        let panelID = try #require(task.operation.taskSpace?.panelID)
        let sessionID = try #require(task.operation.agentLaunch?.sessionID)
        fixture.tasks.sessionRuntimeStore.updateStatus(
            sessionID: sessionID, status: SessionStatus(kind: .needsApproval, summary: "Needs an answer"), at: Date()
        )
        let question = CoordinatorEvent(at: Date(), kind: .question, taskID: task.id,
                                        text: "Where should this go?", sessionID: nil, options: ["Staging only", "Prepare prod"])
        try fixture.session.files.append(question)
        await fixture.chat.refresh()
        let initial = try #require(fixture.card(forTask: task.id))
        #expect(initial.id == question.id.uuidString)
        #expect(initial.options == ["Staging only", "Prepare prod"])
        #expect(initial.answer == nil)
        #expect(initial.thread.isEmpty)
        #expect(initial.packet == nil)
        #expect(initial.task?.defaultReplyTarget == .task)
        #expect(fixture.chat.cardIndex.tasks[task.id]?.hasUnansweredQuestion == true)
        let payload = try #require(fixture.chat.lastPayload)
        let payloadJSON = try #require(try JSONSerialization.jsonObject(with: payload.encoded()) as? [String: Any])
        let jsonItems = try #require(payloadJSON["items"] as? [[String: Any]])
        let jsonCard = try #require(jsonItems.first { $0["id"] as? String == initial.id })
        #expect(jsonCard["answer"] is NSNull)
        #expect(jsonCard["options"] as? [String] == ["Staging only", "Prepare prod"])
        #expect((jsonCard["thread"] as? [[String: Any]])?.isEmpty == true)

        let answer = CoordinatorChatPageEvent.reply(taskID: task.id, version: nil, text: "Staging only",
                                                     cardID: initial.id, questionID: question.id)
        await fixture.chat.handle(answer, from: nil)
        await fixture.chat.refresh()
        let answered = try #require(fixture.card(forTask: task.id))
        #expect(fixture.typed.entries.count == 1)
        let delivery = try #require(fixture.typed.entries.first)
        #expect(delivery.panelID == panelID)
        #expect(delivery.text.hasPrefix("Answer from the task card: "))
        let envelope = try #require(CoordinatorTaskAsk(message: String(delivery.text.dropFirst("Answer from the task card: ".count))))
        #expect(envelope.taskID == task.id)
        #expect(envelope.packetVersion == nil)
        #expect(envelope.questionID == question.id)
        #expect(envelope.text == "Staging only")
        #expect(envelope.replyID != nil)
        #expect(answered.answer == "Staging only")
        #expect(answered.thread.map(\.text) == ["Staging only"])
        #expect(answered.thread.map(\.role) == [.userTask])
        #expect(fixture.chat.cardIndex.tasks[task.id]?.questionAnswered == true)
        #expect(fixture.chat.cardIndex.tasks[task.id]?.hasUnansweredQuestion == false)
        let savedReplies = CoordinatorFiles(directoryURL: fixture.session.files.directoryURL).events().filter { $0.kind == .reply }
        #expect(savedReplies.count == 1)
        #expect(savedReplies.first?.id == envelope.replyID)
        #expect(savedReplies.first?.questionID == question.id)

        // A second click from an old page cannot deliver or append again.
        await fixture.chat.handle(answer, from: nil)
        await fixture.chat.refresh()
        #expect(fixture.typed.entries.count == 1)
        #expect(fixture.session.files.events().filter { $0.kind == .reply }.count == 1)
        #expect(fixture.chat.lastPayload?.notice?.isError == true)

        let restored = CoordinatorChatController(
            store: fixture.tasks.store, taskCoordinator: fixture.tasks.coordinator, session: fixture.session,
            conversations: nil, sessionRuntimeStore: fixture.tasks.sessionRuntimeStore
        )
        await restored.refresh()
        let restoredCard = try #require(restored.lastPayload?.items.compactMap { item -> CoordinatorChatCardView? in
            guard case .card(let card) = item, card.id == initial.id else { return nil }
            return card
        }.first)
        #expect(restoredCard.answer == answered.answer)
        #expect(restoredCard.thread == answered.thread)
        #expect(restored.cardIndex.tasks[task.id]?.questionAnswered == true)
        await restored.handle(answer, from: nil)
        #expect(fixture.typed.entries.count == 1)
        #expect(fixture.session.files.events().filter { $0.kind == .reply }.count == 1)

        // A typed follow-up remains available after the one question answer.
        await restored.handle(.reply(taskID: task.id, version: nil, text: "Keep the coupon row visible too.",
                                     cardID: initial.id, questionID: nil), from: nil)
        await restored.refresh()
        #expect(fixture.typed.entries.count == 2)
        let replies = fixture.session.files.events().filter { $0.kind == .reply }
        #expect(replies.map(\.questionID) == [question.id, nil])
        let followedUp = try #require(restored.lastPayload?.items.compactMap { item -> CoordinatorChatCardView? in
            guard case .card(let card) = item, card.id == initial.id else { return nil }
            return card
        }.first)
        #expect(followedUp.answer == "Staging only")
        #expect(followedUp.thread.map(\.text) == ["Staging only", "Keep the coupon row visible too."])
    }

    @Test func aQuestionRejectsWrongTaskAndUnknownReferencesAndDoesNotRecordAFailedSend() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithoutPacket()
        let other = try await fixture.taskWithoutPacket()
        let question = CoordinatorEvent(at: Date(), kind: .question, taskID: task.id,
                                        text: "Keep the coupon?", sessionID: nil)
        try fixture.session.files.append(question)
        await fixture.chat.refresh()
        await fixture.chat.handle(.reply(taskID: other.id, version: nil, text: "Wrong task",
                                         cardID: question.id.uuidString, questionID: question.id), from: nil)
        let unknown = UUID()
        await fixture.chat.handle(.reply(taskID: task.id, version: nil, text: "Old page",
                                         cardID: unknown.uuidString, questionID: unknown), from: nil)
        // There is no coordinator conversation in this fixture.
        await fixture.chat.handle(.ask(taskID: task.id, version: nil, text: "Ask first",
                                       cardID: question.id.uuidString, questionID: question.id), from: nil)
        await fixture.chat.refresh()
        #expect(fixture.typed.entries.isEmpty)
        #expect(fixture.session.files.events().filter { $0.kind == .reply }.isEmpty)
        #expect(fixture.card(forTask: task.id)?.answer == nil)
        #expect(fixture.card(forTask: task.id)?.thread.isEmpty == true)
        #expect(fixture.chat.cardIndex.tasks[task.id]?.hasUnansweredQuestion == true)
        #expect(fixture.chat.lastPayload?.notice?.isError == true)

        // Refusal releases the question so a later valid task reply works.
        await fixture.chat.handle(.reply(taskID: task.id, version: nil, text: "Keep it",
                                         cardID: question.id.uuidString, questionID: question.id), from: nil)
        await fixture.chat.refresh()
        #expect(fixture.typed.entries.count == 1)
        #expect(fixture.card(forTask: task.id)?.answer == "Keep it")
    }

    @Test func openingATaskKeepsItsNewestQuestionVisibleAfterItIsAnswered() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithPacket()
        let question = CoordinatorEvent(at: Date().addingTimeInterval(1), kind: .question, taskID: task.id,
                                        text: "Staging only?", sessionID: nil)
        try fixture.session.files.append(question)
        await fixture.chat.refresh()
        await fixture.chat.handle(.reply(taskID: task.id, version: nil, text: "Staging only",
                                         cardID: question.id.uuidString, questionID: question.id), from: nil)
        #expect(fixture.chat.show(taskID: task.id))
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.focus?.cardID == question.id.uuidString)
        #expect(fixture.chat.cardIndex.tasks[task.id]?.hasUnansweredQuestion == false)
        #expect(fixture.card(forTask: task.id)?.answer == "Staging only")
        #expect(fixture.card(forTask: task.id)?.answeredQuestionIDs == [question.id])
        // There is one current card; its report history stays reachable.
        #expect(fixture.chat.lastPayload?.items.filter { item in
            guard case .card(let card) = item else { return false }
            return card.task?.id == task.id.uuidString
        }.count == 1)
        #expect(fixture.card(forTask: task.id)?.packetVersions == [1])
    }

    @Test func taskTranscriptRepliesAreCapturedOnceAcrossProjectionRebuildAndSessionExit() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithoutPacket()
        let agent = try #require(fixture.tasks.coordinator.liveAgentSession(of: task))
        let question = CoordinatorEvent(at: Date(), kind: .question, taskID: task.id,
                                        text: "Keep the coupon row?", sessionID: nil)
        try fixture.session.files.append(question)
        let replyID = UUID()
        let answer = CoordinatorTaskAsk(taskID: task.id, title: task.title, packetVersion: nil,
                                        text: "Keep it visible", replyID: replyID, questionID: question.id)
        let nativeID = UUID().uuidString
        let transcriptURL = fixture.tasks.root.appendingPathComponent("task-rollout.jsonl")
        let timestamp = "2026-10-26T10:00:00.000Z"
        // Synthetic records use the native Codex rollout format. The real
        // provider parser and transcript tailer turn them into events.
        let records: [[String: Any]] = [
            ["timestamp": timestamp, "type": "session_meta", "payload": [
                "id": nativeID, "session_id": nativeID, "timestamp": timestamp,
                "cwd": fixture.tasks.projectRoot, "originator": "codex_cli", "source": "cli"
            ]],
            ["timestamp": timestamp, "type": "event_msg", "payload": [
                "type": "user_message", "message": "Answer from the task card: \(answer.message)"
            ]],
            ["timestamp": timestamp, "type": "event_msg", "payload": ["type": "task_started", "turn_id": "thread-turn"]],
            ["timestamp": timestamp, "type": "response_item", "payload": [
                "type": "message", "role": "assistant", "id": "thread-assistant-1", "phase": "commentary",
                "content": [["type": "output_text", "text": "I will keep the coupon row visible."]],
                "internal_chat_message_metadata_passthrough": ["turn_id": "thread-turn"]
            ]],
        ]
        var transcript = Data()
        for record in records {
            transcript.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            transcript.append(10)
        }
        try transcript.write(to: transcriptURL)
        let resume = ManagedAgentResumeRecord(agent: .codex, nativeSessionID: nativeID,
                                             sessionFilePath: transcriptURL.path, cwd: fixture.tasks.projectRoot, capturedAt: Date())
        #expect(fixture.tasks.sessionRuntimeStore.confirmNativeSessionBinding(
            managedSessionID: agent.sessionID, panelID: agent.panelID, record: resume
        ))
        #expect(fixture.tasks.store.send(.updateTerminalPanelResumeRecord(panelID: agent.panelID, resumeRecord: resume)))
        let paths = ToasttyRuntimePaths.resolve(homeDirectoryPath: fixture.tasks.root.path, environment: [
            ToasttyRuntimePaths.environmentKey: fixture.tasks.root.appendingPathComponent("thread-runtime").path
        ])
        func service() -> ConversationService {
            ConversationService(store: fixture.tasks.store, sessionRuntimeStore: fixture.tasks.sessionRuntimeStore,
                                terminalRuntimeRegistry: TerminalRuntimeRegistry(), runtimePaths: paths)
        }
        func controller(_ service: ConversationService) -> CoordinatorChatController {
            CoordinatorChatController(store: fixture.tasks.store, taskCoordinator: fixture.tasks.coordinator,
                                      session: fixture.session, conversations: service,
                                      sessionRuntimeStore: fixture.tasks.sessionRuntimeStore)
        }
        func page(_ service: ConversationService) -> ConversationEventPage? {
            guard let id = service.conversationID(for: agent.panelID),
                  case .page(let page) = service.events(for: id, after: nil, limit: 500) else { return nil }
            return page
        }
        func hasAssistant(_ service: ConversationService, text: String) -> Bool {
            page(service)?.events.contains { event in
                guard case .assistantMessage(let message) = event.payload else { return false }
                return message.text == text
            } == true
        }
        func card(_ chat: CoordinatorChatController) -> CoordinatorChatCardView? {
            chat.lastPayload?.items.compactMap { item -> CoordinatorChatCardView? in
                guard case .card(let card) = item, card.id == question.id.uuidString else { return nil }
                return card
            }.first
        }
        let firstService = service()
        var firstChat: CoordinatorChatController? = controller(firstService)
        defer { firstService.setTaskPanelIDs([]) }
        await firstChat?.refresh()
        await fixture.tasks.waitUntil("the real task tailer reads its assistant message") {
            hasAssistant(firstService, text: "I will keep the coupon row visible.")
        }
        await firstChat?.refresh()
        let captured = try #require(firstChat.flatMap(card))
        #expect(captured.answer == answer.text)
        #expect(captured.thread.map(\.role) == [.userTask, .agent])
        #expect(captured.thread.map(\.text) == [answer.text, "I will keep the coupon row visible."])
        #expect(firstService.localPanelIDs.contains(agent.panelID) == false)
        #expect(fixture.typed.entries.isEmpty)

        // Explicit stop clears the terminal's resume record. Task read demand
        // keeps the confirmed transcript source until the thread detaches.
        fixture.tasks.sessionRuntimeStore.stopSession(sessionID: agent.sessionID, at: Date())
        #expect(fixture.tasks.coordinator.liveAgentSession(of: task) == nil)
        let final: [String: Any] = ["timestamp": "2026-10-26T10:00:01.000Z", "type": "response_item", "payload": [
            "type": "message", "role": "assistant", "id": "thread-assistant-2", "phase": "final",
            "content": [["type": "output_text", "text": "The coupon row now stays visible."]],
            "internal_chat_message_metadata_passthrough": ["turn_id": "thread-turn"]
        ]]
        let file = try FileHandle(forWritingTo: transcriptURL)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: JSONSerialization.data(withJSONObject: final, options: [.sortedKeys]))
        try file.write(contentsOf: Data([10]))
        await firstChat?.refresh()
        await fixture.tasks.waitUntil("the inactive terminal tailer reads the final reply") {
            hasAssistant(firstService, text: "The coupon row now stays visible.")
        }
        await firstChat?.refresh()
        let finished = try #require(firstChat.flatMap(card))
        #expect(finished.thread.map(\.role) == [.userTask, .agent, .agent])
        #expect(finished.thread.last?.text == "The coupon row now stays visible.")
        let saved = fixture.session.files.events().filter { $0.kind == .reply }
        #expect(saved.count == 3)
        #expect(Set(saved.compactMap(\.sourceID)).count == 3)
        #expect(saved.filter { $0.id == replyID }.count == 1)
        let firstRun = try #require(page(firstService)?.projectionRunID)
        firstChat = nil
        firstService.setTaskPanelIDs([])

        // Republish the saved native source to exercise a fresh projection
        // rebuild as a restored terminal would, independently of the cache.
        #expect(fixture.tasks.store.send(.updateTerminalPanelResumeRecord(panelID: agent.panelID, resumeRecord: resume)))
        let rebuiltService = service()
        let rebuiltChat = controller(rebuiltService)
        defer { rebuiltService.setTaskPanelIDs([]) }
        await rebuiltChat.refresh()
        await fixture.tasks.waitUntil("the new projection replays the inactive task transcript") {
            hasAssistant(rebuiltService, text: "The coupon row now stays visible.")
        }
        await rebuiltChat.refresh()
        #expect(page(rebuiltService)?.projectionRunID != firstRun)
        #expect(card(rebuiltChat)?.thread == finished.thread)
        #expect(fixture.session.files.events().filter { $0.kind == .reply } == saved)
    }

    @Test func aDraftFromAnAddressedThreadStillSendsAfterItsFirstPacketArrives() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithoutPacket()
        let ask = CoordinatorEvent(at: Date(), kind: .reply, taskID: task.id,
            text: "Inspect this task", sessionID: nil, threadRole: .userCoordinator)
        try fixture.session.files.append(ask)
        await fixture.chat.refresh()
        let anchorID = try #require(fixture.card(forTask: task.id)?.id)
        #expect(anchorID == ask.id.uuidString)
        let preparation = try fixture.tasks.coordinator.preparePacketPublish(taskID: task.id,
            packetJSON: Data(#"{"summary":"Adds the totals bar","look_at":"The bar at 390px","not_verified":[]}"#.utf8), screenshotPaths: [])
        _ = try await fixture.tasks.coordinator.finishPacketPublish(preparation)
        await fixture.chat.refresh()
        #expect(fixture.card(forTask: task.id)?.id != anchorID)
        await fixture.chat.handle(.reply(taskID: task.id, version: nil, text: "Keep this original draft",
                                        cardID: anchorID), token: 73, from: nil)
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.ack == .init(token: 73, ok: true))
        #expect(fixture.typed.entries.last?.text.contains("Keep this original draft") == true)
    }

    @Test func anUnavailableComposerProjectReturnsItsFailedAcknowledgement() async throws {
        let fixture = try await Fixture()
        await fixture.chat.handle(.project(id: "/no-longer-a-project", text: "Fix totals"), token: 74, from: nil)
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.ack == .init(token: 74, ok: false))
        #expect(fixture.typed.entries.isEmpty)
    }

    @Test func reportHistoryNavigatesTheExistingBrowserAndReportsARefusal() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithPacket()
        var loads: [(UUID, String)] = []
        var canLoad = true
        let chat = CoordinatorChatController(store: fixture.tasks.store, taskCoordinator: fixture.tasks.coordinator,
            session: fixture.session, conversations: nil, sessionRuntimeStore: fixture.tasks.sessionRuntimeStore,
            loadURLInPanel: { panelID, url in
                loads.append((panelID, url))
                guard canLoad else { return false }
                _ = fixture.tasks.store.send(.updateWebPanelMetadata(panelID: panelID, title: nil, url: url))
                return true
            })
        await chat.handle(.openReport(taskID: task.id, version: 1, screenshot: nil), from: nil)
        #expect(loads.isEmpty) // Creation uses the new panel's initial URL.
        await chat.handle(.openReport(taskID: task.id, version: 2, screenshot: nil), from: nil)
        let panelID = try #require(loads.first?.0)
        #expect(loads.map(\.1) == [CoordinatorChatController.reportURL(taskID: task.id, version: 2, screenshot: nil)])
        await chat.handle(.openReport(taskID: task.id, version: 2, screenshot: nil), from: nil)
        #expect(loads.count == 1) // Selecting the current report keeps its scroll.
        canLoad = false
        await chat.handle(.openReport(taskID: task.id, version: 1, screenshot: nil), from: nil)
        await chat.refresh()
        #expect(loads.last?.0 == panelID)
        #expect(chat.lastPayload?.notice?.isError == true)
        #expect(chat.lastPayload?.notice?.text == "The report could not open in its browser tab.")
        for url in ["toastty://coordinator/report/\(task.id.uuidString)/1", "http://localhost:1234/report/1"] {
            #expect(BrowserPanelRuntime.normalizedUserEnteredURLString(url) == url)
        }
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
        let questionID = UUID()
        #expect(CoordinatorChatPageEvent(body: ["type": "reply", "taskID": taskID.uuidString, "text": "ok",
                                               "cardID": questionID.uuidString, "questionID": questionID.uuidString])
            == .reply(taskID: taskID, version: nil, text: "ok", cardID: questionID.uuidString, questionID: questionID))
        #expect(CoordinatorChatPageEvent(body: ["type": "reply", "taskID": taskID.uuidString, "text": "ok", "questionID": "bad"]) == nil)
        for type in ["reply", "ask"] {
            #expect(CoordinatorChatPageEvent(body: ["type": type, "taskID": taskID.uuidString, "text": "ok", "cardID": 12]) == nil)
            #expect(CoordinatorChatPageEvent(body: ["type": type, "taskID": taskID.uuidString, "text": "ok", "questionID": 12]) == nil)
            #expect(CoordinatorChatPageEvent(body: ["type": type, "taskID": taskID.uuidString, "text": "ok", "version": -1]) == nil)
        }
        #expect(CoordinatorChatPageEvent(body: ["type": "reply", "taskID": taskID.uuidString, "text": "ok", "version": NSNull()])
            == .reply(taskID: taskID, version: nil, text: "ok"))
        #expect(CoordinatorChatPageEvent(body: ["type": "ask", "taskID": taskID.uuidString, "text": "ok", "version": NSNull()])
            == .ask(taskID: taskID, version: nil, text: "ok"))
        #expect(CoordinatorChatPageEvent(body: ["type": "openURL", "url": "file:///etc/passwd"]) == nil)
        #expect(CoordinatorChatPageEvent(body: ["type": "openURL", "url": "https://example.com"]) == .openURL("https://example.com"))
        #expect(CoordinatorChatPageEvent(body: ["type": "merge"]) == nil)
        #expect(CoordinatorChatPageEvent(body: "ready") == nil)
        #expect(CoordinatorChatPageEvent(body: ["type": "projectFilter", "project": "/work/app"]) == .projectFilter("/work/app"))
        #expect(CoordinatorChatPageEvent(body: ["type": "projectFilter", "project": 12]) == nil)
        #expect(CoordinatorChatPageEvent(body: ["type": "showView", "view": "today"]) == .showView(.today))
        #expect(CoordinatorChatPageEvent(body: ["type": "showView", "view": "chat"]) == nil)
        #expect(CoordinatorSummaryPageBridge.accepts(.send("hello"), isSummary: true) == false)
        #expect(CoordinatorSummaryPageBridge.accepts(.project(id: "/project", text: "hello"), isSummary: true) == false)
        #expect(CoordinatorSummaryPageBridge.accepts(.taskMenu(taskID: UUID(), rect: .zero), isSummary: true) == false)
        #expect(CoordinatorSummaryPageBridge.accepts(.answerRoute(questionID: UUID(), optionIndex: 0), isSummary: true) == false)
        #expect(CoordinatorSummaryPageBridge.accepts(.archiveTask(UUID()), isSummary: true) == false)
        #expect(CoordinatorSummaryPageBridge.accepts(.answerRoute(questionID: UUID(), optionIndex: 0), isSummary: false))
        #expect(CoordinatorSummaryPageBridge.accepts(.archiveTask(UUID()), isSummary: false))
        #expect(CoordinatorSummaryPageBridge.accepts(.taskAction(rowID: "row", actionID: "open"), isSummary: true))
        #expect(CoordinatorSummaryPageBridge.accepts(.taskAction(rowID: "row", actionID: "open"), isSummary: false) == false)
        #expect(CoordinatorSummaryPageBridge.accepts(.activate(view: .tasks, selectedRowID: nil), isSummary: false) == false)

        func route(_ string: String) -> ToasttyCoordinatorPageRoute? { URL(string: string).flatMap(ToasttyCoordinatorPageRoute.init(url:)) }
        let id = taskID.uuidString
        #expect(route("toastty://coordinator/today") == .summary)
        #expect(route("toastty://coordinator/tasks") == .summary)
        #expect(route("toastty://coordinator/today?other=1") == nil)
        #expect(route("toastty://coordinator/today/extra") == nil)
        #expect(route("toastty://coordinator/%74oday") == nil)
        #expect(route("toastty://user@coordinator/today") == nil)
        #expect(route("toastty://coordinator:123/today") == nil)
        #expect(route("https://coordinator/today") == nil)
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
        #expect(await fixture.chat.sendReportMarks(taskID: task.id, version: 1, marks: marks) == .sent)
        #expect(fixture.typed.entries.last?.text == "Review note on packet v1: 1 marks on the screenshots:\n1. Move the bar up [after-390]")
        await fixture.chat.refresh()
        let card = try #require(fixture.card(forTask: task.id))
        #expect(card.thread.map(\.text) == ["1 marks on the screenshots:\n1. Move the bar up [after-390]"])
        #expect(card.thread.map(\.role) == [.userTask])
        let count = fixture.typed.entries.count
        #expect(await fixture.chat.sendReportMarks(taskID: task.id, version: 2, marks: marks) == .rejected)
        #expect(await fixture.chat.sendReportMarks(taskID: task.id, version: 1, marks: [.init(shot: "missing", note: "Fix", x: 0, y: 0)]) == .rejected)
        #expect(await fixture.chat.sendReportMarks(taskID: task.id, version: 1, marks: [.init(shot: "after-390", note: " ", x: 0, y: 0)]) == .rejected)
        #expect(await fixture.chat.sendReportMarks(taskID: task.id, version: 1, marks: [.init(shot: "after-390", note: "Fix", x: .nan, y: 0)]) == .rejected)
        #expect(fixture.typed.entries.count == count)
        // A merged task can be finished before doneAt or archivedAt is set.
        // This is a rejected send, rather than uncertain delivery.
        try fixture.tasks.coordinator.records.save(id: task.id) { $0.mergedAt = Date() }
        #expect(await fixture.chat.sendReportMarks(taskID: task.id, version: 1, marks: marks) == .rejected)
        #expect(fixture.typed.entries.count == count)
        try fixture.tasks.coordinator.records.save(id: task.id) { $0.archivedAt = Date() }
        #expect(await fixture.chat.sendReportMarks(taskID: task.id, version: 1, marks: marks) == .rejected)
        #expect(fixture.typed.entries.count == count)
    }

    @Test func aComposerThreadCardAcceptsItsOwnFollowup() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithoutPacket()
        let first = CoordinatorEvent(at: Date(), kind: .reply, taskID: task.id,
                                     text: "What changed?", sessionID: nil, threadRole: .userCoordinator)
        try fixture.session.files.append(first)
        await fixture.chat.refresh()
        let anchor = try #require(fixture.card(forTask: task.id))
        #expect(anchor.id == first.id.uuidString)
        await fixture.chat.handle(.reply(taskID: task.id, version: nil, text: "Keep the coupon visible.",
                                        cardID: anchor.id), from: nil)
        await fixture.chat.refresh()
        #expect(fixture.typed.entries.count == 1)
        #expect(fixture.card(forTask: task.id)?.thread.map(\.text) == ["What changed?", "Keep the coupon visible."])
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

    @Test func suggestionsIgnoreOnlyTheAutomaticFirstLaunchMessage() {
        var transcript = CoordinatorChatTranscript()
        let conversation = RemoteConversationID(rawValue: UUID())
        var sequence: UInt64 = 0
        func message(_ text: String, origin: ConversationMessageOrigin = .unknown) -> ConversationEvent {
            sequence += 1
            return ConversationEvent(conversationID: conversation, sequence: sequence, eventID: "\(sequence)", timestamp: Date(), provider: .claude, payload: .userMessage(.init(text: text, origin: origin)))
        }
        transcript.follow(conversation)
        transcript.apply(message("  \n "))
        let startup = message("  \(CoordinatorSessionController.initialPrompt)\n")
        transcript.apply(startup)
        transcript.apply(startup)
        #expect(transcript.hasUserRequests == false)
        let enriched = ConversationEvent(conversationID: conversation, sequence: startup.sequence, eventID: startup.eventID, timestamp: startup.timestamp, provider: .claude, payload: .userMessage(.init(text: CoordinatorSessionController.initialPrompt, origin: .local)))
        transcript.apply(enriched)
        #expect(transcript.hasUserRequests == false)
        transcript.reset()
        transcript.apply(enriched)
        #expect(transcript.hasUserRequests == false)
        transcript.apply(message(CoordinatorSessionController.initialPrompt))
        #expect(transcript.hasUserRequests)
        var restarted = CoordinatorChatTranscript()
        restarted.follow(conversation)
        restarted.apply(startup)
        let nextConversation = RemoteConversationID(rawValue: UUID())
        restarted.follow(nextConversation)
        restarted.apply(ConversationEvent(conversationID: nextConversation, sequence: 1, eventID: "next-start", timestamp: Date(), provider: .claude, payload: .userMessage(.init(text: CoordinatorSessionController.initialPrompt))))
        #expect(restarted.hasUserRequests == false)
        restarted.apply(ConversationEvent(conversationID: nextConversation, sequence: 2, eventID: "next-request", timestamp: Date(), provider: .claude, payload: .userMessage(.init(text: "What needs me?"))))
        #expect(restarted.hasUserRequests)
        for index in 0...CoordinatorChatTranscript.maximumItems {
            transcript.apply(ConversationEvent(conversationID: conversation, sequence: UInt64(100 + index), eventID: "assistant-\(index)", timestamp: Date(), provider: .claude, payload: .assistantMessage(.init(text: "Working"))))
        }
        #expect(!transcript.items.contains(where: { $0.role == "user" }))
        #expect(transcript.hasUserRequests)
        transcript.reset()
        #expect(transcript.hasUserRequests)
        transcript.follow(RemoteConversationID(rawValue: UUID()))
        #expect(transcript.hasUserRequests)
        for origin in [ConversationMessageOrigin.local, .remote] {
            var fresh = CoordinatorChatTranscript()
            fresh.follow(conversation)
            fresh.apply(message(CoordinatorSessionController.initialPrompt, origin: origin))
            #expect(fresh.hasUserRequests)
        }
    }

    @Test func taskMenuEventsRequireAFiniteVisibleRectangle() {
        let taskID = UUID()
        func event(x: Double = 10, y: Double = 20, width: Double = 30, height: Double = 40) -> CoordinatorChatPageEvent? {
            CoordinatorChatPageEvent(body: ["type": "taskMenu", "taskID": taskID.uuidString,
                                            "x": x, "y": y, "width": width, "height": height])
        }
        #expect(event() == .taskMenu(taskID: taskID, rect: CGRect(x: 10, y: 20, width: 30, height: 40)))
        #expect(event(x: .nan) == nil)
        #expect(event(y: .infinity) == nil)
        #expect(event(width: 0) == nil)
        #expect(event(height: -1) == nil)
        #expect(event(x: 100_001) == nil)
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
        #expect(CoordinatorTaskAsk(message: noPacket.message)?.replyID == nil)
        #expect(CoordinatorTaskAsk(message: noPacket.message)?.questionID == nil)
        let referenced = CoordinatorTaskAsk(taskID: taskID, title: "Fix totals", packetVersion: nil, text: "ok\nkeep it",
                                            replyID: UUID(), questionID: UUID())
        #expect(CoordinatorTaskAsk(message: referenced.message) == referenced)
        let followup = CoordinatorTaskAsk(taskID: taskID, title: "Fix totals", packetVersion: 2, text: "One more thing", replyID: UUID())
        #expect(CoordinatorTaskAsk(message: followup.message) == followup)
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

        transcript.apply(ConversationEvent(
            conversationID: conversation, sequence: 3, eventID: "3", timestamp: Date(), provider: .claude,
            payload: .userMessage(.init(text: referenced.message))
        ))
        #expect(transcript.items.last?.text == referenced.text)
        #expect(transcript.items.last?.replyID == referenced.replyID)
        #expect(transcript.items.last?.questionID == referenced.questionID)
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
