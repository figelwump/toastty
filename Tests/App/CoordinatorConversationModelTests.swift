import Combine
import ConversationUI
import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// The model reads real service snapshots and cursor pages. Only the terminal
/// surface is absent; these tests never launch an agent or create a listener.
@MainActor
struct CoordinatorConversationModelTests {
    @MainActor
    private final class Fixture {
        let store = AppStore(persistTerminalFontPreference: false)
        let runtime = SessionRuntimeStore(sendSessionStatusNotification: { _, _, _, _, _ in })
        let terminals = TerminalRuntimeRegistry(focusCoordinator: TerminalFocusCoordinator(), activateApp: {
            Issue.record("Conversation model tests must not activate the app.")
        })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-conversation-model-\(UUID())")
        let panelID: UUID
        let conversationID: RemoteConversationID
        let service: ConversationService
        let model: CoordinatorConversationModel
        private enum FixtureError: Error { case promptNotOpen }
        private var observationIndex = 0
        private let startedAt = Date()

        init() throws {
            runtime.bind(store: store)
            let selection = try #require(store.state.selectedWorkspaceSelection())
            panelID = try #require(selection.workspace.focusedPanelID)
            runtime.startSession(sessionID: UUID().uuidString, agent: .claude, panelID: panelID,
                windowID: selection.windowID, workspaceID: selection.workspaceID,
                codexStatusTrackingSource: .externallyReported, cwd: root.path, repoRoot: nil, at: startedAt)
            let paths = ToasttyRuntimePaths.resolve(environment: [ToasttyRuntimePaths.environmentKey: root.path])
            service = ConversationService(store: store, sessionRuntimeStore: runtime,
                terminalRuntimeRegistry: terminals, runtimePaths: paths)
            service.setLocalPanelIDs([panelID])
            conversationID = try #require(service.conversationID(for: panelID))
            model = CoordinatorConversationModel(service: service, panelID: panelID)
            model.refresh()
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func observe(_ payload: ProviderObservationPayload, fingerprint: String? = nil) {
            observationIndex += 1
            service.projectionStore.ingest([.init(
                timestamp: startedAt.addingTimeInterval(Double(observationIndex)),
                fingerprint: fingerprint ?? "model-observation-\(observationIndex)", payload: payload
            )], for: conversationID)
            service.syncConversations()
        }

        func present(
            _ kind: RemotePendingInteraction.Kind = .question,
            callID: String = "question-call", responseID: String? = "response-one",
            questions: [RemoteInteractionQuestion]? = nil, hasQuestions: Bool = true,
            expiresAt: Date? = Date().addingTimeInterval(300)
        ) throws -> RemotePendingInteraction {
            observe(.interactionPresented(.init(kind: kind, providerCallID: callID,
                prompt: "Choose an option", questions: hasQuestions ? (questions ?? Self.questions) : nil,
                responseID: responseID, responseExpiresAt: expiresAt)))
            model.refresh()
            return try #require(model.snapshot?.pendingInteractions.first { $0.providerCallID == callID })
        }

        func rebind() throws -> RemoteInputEpoch {
            service.projectionStore.noteBinding(for: conversationID, reason: .runtimeResumed,
                bindingID: UUID(), at: Date())
            service.projectionStore.bootstrapConfirmedOpenPrompt(for: conversationID, at: Date())
            service.syncConversations()
            if case .openPrompt(let epoch) = service.projectionStore.projectorState(for: conversationID)?.inputAvailability { return epoch }
            throw FixtureError.promptNotOpen
        }

        func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while condition() == false {
                guard ContinuousClock.now < deadline else {
                    Issue.record("Timed out waiting for \(description)")
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        static let questions = [RemoteInteractionQuestion(id: "q", header: "Choice", question: "Which option?", options: [
            .init(id: "first", label: "First"), .init(id: "second", label: "Second")
        ])]
    }

    private func assistantMessages(_ model: CoordinatorConversationModel) -> [String] {
        model.events.compactMap { event in
            guard case .assistantMessage(let payload) = event.payload else { return nil }
            return payload.text
        }
    }

    @Test
    func serviceInvalidationsAndResnapshotRefreshHistoryWithoutLosingDraftOrDuplicatingEvents() async throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        f.model.draft = "An unfinished native reply"
        let attachment = RemoteMessageAttachment(filename: "notes.txt", data: Data("Local notes".utf8))
        f.model.attachments = [attachment]
        await Task.yield()

        f.observe(.transcript(.assistantMessage(.init(text: "First result"))), fingerprint: "assistant-first")
        try await f.waitUntil("the first service invalidation") { assistantMessages(f.model) == ["First result"] }
        f.observe(.transcript(.assistantMessage(.init(text: "Second result"))), fingerprint: "assistant-second")
        try await f.waitUntil("the next service invalidation") { assistantMessages(f.model) == ["First result", "Second result"] }
        let generation = try #require(f.model.snapshot?.summary.projectionGeneration)

        f.service.projectionStore.forceResnapshot(for: f.conversationID, bindingID: UUID(), at: Date())
        f.observe(.transcript(.assistantMessage(.init(text: "First result"))), fingerprint: "assistant-first")
        f.observe(.transcript(.assistantMessage(.init(text: "Second result"))), fingerprint: "assistant-second")
        try await f.waitUntil("the new history generation") {
            f.model.snapshot?.summary.projectionGeneration != generation && assistantMessages(f.model) == ["First result", "Second result"]
        }
        f.model.refresh()
        f.model.refresh()

        #expect(assistantMessages(f.model) == ["First result", "Second result"])
        #expect(Set(f.model.events.map(\.eventID)).count == f.model.events.count)
        #expect(f.model.draft == "An unfinished native reply")
        #expect(f.model.attachments == [attachment])
    }

    @Test
    func closedQuestionAndPermissionChannelsCannotBeReenabledByRefreshOrEditing() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        for kind in [RemotePendingInteraction.Kind.question, .permission] {
            let interaction = try f.present(kind, callID: kind.rawValue)
            f.model.editAnswer(.selectOnly(questionID: "q", optionID: "first"), interaction: interaction)
            #expect(f.model.answerStates[interaction.id]?.canSubmit == true)

            f.observe(.transcript(.interactionResponseClosed(.init(interactionID: interaction.id, reason: .expired))))
            for _ in 0..<3 {
                f.model.refresh()
                let current = try #require(f.model.snapshot?.pendingInteractions.first { $0.id == interaction.id })
                #expect(current.responseID == nil)
                f.model.editAnswer(.selectOnly(questionID: "q", optionID: "second"), interaction: current)
                #expect(f.model.answerStates[interaction.id]?.canSubmit != true)
                if case .unavailable = f.model.answerStates[interaction.id]?.status {} else {
                    Issue.record("A closed response channel must keep the form unavailable.")
                }
            }
        }
    }

    @Test
    func newResponseOrInputEpochDropsTheAnswerStateForThePreviousBinding() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let first = try f.present()
        f.model.editAnswer(.selectOnly(questionID: "q", optionID: "first"), interaction: first)
        #expect(f.model.answerStates[first.id]?.canSubmit == true)
        f.observe(.transcript(.interactionResponseClosed(.init(interactionID: first.id, reason: .expired))))
        f.model.refresh()

        let second = try f.present(responseID: "response-two")
        #expect(second.id == first.id)
        #expect(second.inputEpoch == first.inputEpoch)
        #expect(f.model.answerStates[second.id]?.drafts.isEmpty == true)
        #expect(f.model.answerStates[second.id]?.status == .editing)
        f.model.editAnswer(.selectOnly(questionID: "q", optionID: "second"), interaction: second)
        #expect(f.model.answerStates[second.id]?.canSubmit == true)

        _ = try f.rebind()
        let third = try f.present(responseID: "response-two")
        #expect(third.id == second.id)
        #expect(third.inputEpoch != second.inputEpoch)
        #expect(f.model.answerStates[third.id]?.drafts.isEmpty == true)
        #expect(f.model.answerStates[third.id]?.canSubmit == false)
        #expect(f.model.answerStates[third.id]?.status == .editing)
        f.model.editAnswer(.selectOnly(questionID: "q", optionID: "first"), interaction: third)
        f.model.answer(second)
        #expect(f.model.answerStates[third.id]?.status == .editing)
        #expect(f.model.answerStates[third.id]?.drafts["q"]?.selectedOptionIDs == ["first"])

        // A cursor reset replays earlier channel closures. They must not close
        // a later response that has the same stable interaction ID.
        f.service.projectionStore.forceResnapshot(for: f.conversationID, bindingID: UUID(), at: Date())
        f.observe(.interactionPresented(.init(kind: .question, providerCallID: "question-call", prompt: "Choose an option",
            questions: Fixture.questions, responseID: "old-replayed-response", responseExpiresAt: Date().addingTimeInterval(300))))
        f.observe(.transcript(.interactionResponseClosed(.init(interactionID: third.id, reason: .expired))))
        f.observe(.interactionPresented(.init(kind: .question, providerCallID: "question-call", prompt: "Choose an option",
            questions: Fixture.questions, responseID: "new-live-response", responseExpiresAt: Date().addingTimeInterval(300))))
        f.model.refresh()
        #expect(f.model.snapshot?.pendingInteractions.first?.responseID == "new-live-response")
        #expect(f.model.answerStates[third.id]?.status == .editing)
        #expect(f.model.answerStates[third.id]?.drafts.isEmpty == true)
    }

    @Test
    func missingOrExpiredSemanticResponseNeverLeavesAnEnabledForm() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        let interaction = try f.present()
        f.model.editAnswer(.selectOnly(questionID: "q", optionID: "first"), interaction: interaction)
        #expect(f.model.answerStates[interaction.id]?.canSubmit == true)

        let readOnly = try f.present(responseID: nil, hasQuestions: false)
        #expect(readOnly.id == interaction.id)
        #expect(readOnly.questions == nil)
        #expect(f.model.answerStates[readOnly.id]?.canSubmit != true)
        f.model.refresh()
        #expect(f.model.answerStates[readOnly.id]?.canSubmit != true)

        let noChannel = try f.present(callID: "no-channel", responseID: nil)
        f.model.editAnswer(.selectOnly(questionID: "q", optionID: "first"), interaction: noChannel)
        #expect(f.model.answerStates[noChannel.id]?.canSubmit != true)
        let expired = try f.present(callID: "expired", expiresAt: Date().addingTimeInterval(-1))
        f.model.editAnswer(.selectOnly(questionID: "q", optionID: "first"), interaction: expired)
        #expect(f.model.answerStates[expired.id]?.canSubmit != true)
    }

    @Test
    func draftReleaseConfirmationCannotApplyToAChangedSessionHold() throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        _ = try f.rebind()
        f.service.noteLocalInput(panelID: f.panelID)
        f.model.refresh()
        let inspected = try #require(f.model.draftHold)
        _ = try f.rebind()
        f.service.noteLocalInput(panelID: f.panelID)
        f.model.refresh()
        let current = try #require(f.model.draftHold)
        #expect(current != inspected)
        f.model.releaseTerminalDraft(expected: inspected)
        #expect(f.model.draftHold == current)
        #expect(f.model.notice?.contains("Inspect it again") == true)
    }

    @Test
    func unchangedUncertainRetryKeepsItsRequestIdentityAndEditedMessageGetsANewIdentity() async throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        _ = try f.rebind()
        var requests: [RemoteMessageSendRequest] = []
        // A bounded transport fixture controls the uncertain return. Reads
        // and input epochs still come from the real shared service.
        let model = CoordinatorConversationModel(service: f.service, panelID: f.panelID,
            sendMessage: { request in requests.append(request); return .uncertain })
        model.refresh()
        model.draft = "Inspect the evidence"
        model.attachments = [.init(filename: "note.txt", data: Data("Evidence".utf8))]
        await model.send()
        #expect(model.draft == "Inspect the evidence")
        #expect(model.attachments.count == 1)
        #expect(model.notice?.contains("uncertain") == true)
        await model.send()
        #expect(requests.count == 2)
        #expect(requests[0].clientRequestID == requests[1].clientRequestID)
        model.draft = "Inspect the updated evidence"
        await model.send()
        #expect(requests.count == 3)
        #expect(requests[2].clientRequestID != requests[1].clientRequestID)
    }

    @Test
    func acceptedResultFromOldBindingCannotClearTheDraftForInspection() async throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        _ = try f.rebind()
        var finish: CheckedContinuation<RemoteMessageSendResult, Never>?
        let model = CoordinatorConversationModel(service: f.service, panelID: f.panelID,
            sendMessage: { _ in await withCheckedContinuation { finish = $0 } })
        model.refresh()
        let sentEpoch = try #require(model.inputEpoch)
        model.draft = "Message for the old session"
        let pending = Task { await model.send() }
        try await f.waitUntil("the pending send") { finish != nil }
        let continuation = try #require(finish)
        _ = try f.rebind()
        model.refresh()
        continuation.resume(returning: .accepted(epoch: sentEpoch))
        await pending.value
        #expect(model.draft == "Message for the old session")
        #expect(model.hasDraftFromPreviousSession)
        #expect(!model.canSend)
        #expect(model.notice?.contains("session changed") == true)
    }

    @Test
    func editsDuringRejectedSendKeepNewDraftFilesAndRefreshTheInputEpoch() async throws {
        let f = try Fixture()
        defer { f.service.setLocalPanelIDs([]) }
        _ = try f.rebind()
        f.model.refresh()
        let previousEpoch = try #require(f.model.inputEpoch)
        let first = RemoteMessageAttachment(filename: "first.txt", data: Data("First attachment".utf8))
        let newer = RemoteMessageAttachment(filename: "newer.txt", data: Data("New attachment".utf8))
        f.model.draft = "The draft being submitted"
        f.model.attachments = [first]
        f.terminals.setAutomationPromptStateHandlerForTesting { _ in .idleAtPrompt }
        var deliveries = 0
        f.terminals.setAutomationSendTextHandlerForTesting { _, _, _, _ in deliveries += 1; return false }
        var nextEpoch: RemoteInputEpoch?
        // Published submission state is the real boundary after send captures
        // its input, before the service stages attachments and rechecks epochs.
        let observation = f.model.$sending.dropFirst().sink { sending in
            guard sending else { return }
            f.model.draft = "New work written during the send"
            f.model.attachments.append(newer)
            do { nextEpoch = try f.rebind() }
            catch { Issue.record("Could not advance the input binding: \(error)") }
        }
        defer { observation.cancel() }

        await f.model.send()
        f.model.refresh()

        #expect(nextEpoch != nil && nextEpoch != previousEpoch)
        #expect(f.model.inputEpoch == nextEpoch)
        #expect(f.model.draft == "New work written during the send")
        #expect(f.model.attachments == [first, newer])
        #expect(f.model.sending == false)
        #expect(f.model.notice != nil)
        #expect(f.model.hasDraftFromPreviousSession)
        #expect(f.model.canSend == false)
        #expect(deliveries == 0)
        f.model.clearDraftForCurrentSession()
        #expect(f.model.draft.isEmpty && f.model.attachments.isEmpty)
        #expect(f.model.hasDraftFromPreviousSession == false)
        f.model.draft = "A new message for the current session"
        #expect(f.model.canSend)
    }
}
