import Combine
import ConversationUI
import CoreState
import Foundation
import RemoteProtocol

/// One app-owned composer and transcript. Windows never acquire separate input authority.
@MainActor
final class CoordinatorConversationModel: ObservableObject {
    @Published var draft = "" { didSet { recordDraftOwner() } }
    @Published var attachments: [RemoteMessageAttachment] = [] { didSet { recordDraftOwner() } }
    @Published private(set) var snapshot: RemoteConversationSnapshot?
    @Published private(set) var events: [ConversationEvent] = []
    @Published private(set) var sending = false
    @Published private(set) var historyTruncated = false
    @Published var notice: String?
    @Published private(set) var answerStates: [RemotePendingInteraction.ID: ConversationInteractionAnswerState] = [:]
    private let service: ConversationService
    private let sendMessage: @MainActor (RemoteMessageSendRequest) async -> RemoteMessageSendResult
    private let panelIDProvider: () -> UUID?
    private var conversationID: RemoteConversationID?
    private var cursor: ConversationEventCursor?
    private var currentBindingID: UUID?
    private var draftConversationID: RemoteConversationID?
    private var draftBindingID: UUID?
    private struct PendingSend {
        let conversationID: RemoteConversationID
        let text: String
        let attachments: [RemoteMessageAttachment]
        let requestID: String
    }
    private var pendingSend: PendingSend?
    private struct AnswerBinding: Equatable {
        let epoch: RemoteInputEpoch
        let responseID: String?
    }
    private var answerBindings: [RemotePendingInteraction.ID: AnswerBinding] = [:]
    private var observation: Task<Void, Never>?
    private var sessionSubscription: AnyCancellable?

    convenience init(service: ConversationService, session: CoordinatorSessionController) {
        self.init(service: service, panelIDProvider: { [weak session] in session?.identity?.panelID })
        sessionSubscription = session.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    convenience init(service: ConversationService, panelID: UUID,
                     sendMessage: (@MainActor (RemoteMessageSendRequest) async -> RemoteMessageSendResult)? = nil) {
        self.init(service: service, panelIDProvider: { panelID }, sendMessage: sendMessage)
    }

    private init(service: ConversationService, panelIDProvider: @escaping () -> UUID?,
                 sendMessage: (@MainActor (RemoteMessageSendRequest) async -> RemoteMessageSendResult)? = nil) {
        self.service = service
        self.sendMessage = sendMessage ?? { await service.sendLocal($0) }
        self.panelIDProvider = panelIDProvider
        observation = Task { @MainActor [weak self, service] in
            for await _ in service.changes() {
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    deinit { observation?.cancel() }

    var inputEpoch: RemoteInputEpoch? {
        if case .openPrompt(let epoch) = snapshot?.summary.inputAvailability { return epoch }
        return nil
    }

    var hasDraftFromPreviousSession: Bool {
        if let owner = draftConversationID, owner != conversationID { return true }
        if let owner = draftBindingID, let currentBindingID, owner != currentBindingID { return true }
        return false
    }

    private var hasSendableDraft: Bool {
        !sending && !hasDraftFromPreviousSession
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var canSend: Bool {
        hasSendableDraft && (inputEpoch != nil || snapshot?.summary.inputControl?.canQueue == true)
    }

    var canSteer: Bool {
        hasSendableDraft && snapshot?.summary.inputControl?.canSteer == true
            && snapshot?.summary.inputControl?.turnEpoch != nil
    }

    func clearDraftForCurrentSession() {
        draft = ""
        attachments = []
        notice = nil
    }

    private func recordDraftOwner() {
        if draft.isEmpty && attachments.isEmpty {
            draftConversationID = nil
            draftBindingID = nil
            pendingSend = nil
        } else if draftConversationID == nil {
            draftConversationID = conversationID
            draftBindingID = currentBindingID
        } else if draftBindingID == nil, draftConversationID == conversationID {
            draftBindingID = currentBindingID
        }
    }

    func refresh() {
        let id = panelIDProvider().flatMap { service.conversationID(for: $0) }
        if id != conversationID {
            conversationID = id
            currentBindingID = nil
            notice = nil
            cursor = nil
            events = []
            historyTruncated = false
            answerStates = [:]
            answerBindings = [:]
        }
        guard let id else {
            if snapshot != nil { snapshot = nil }
            return
        }
        let nextSnapshot = service.localSnapshot(for: id, at: Date())
        if snapshot != nextSnapshot { snapshot = nextSnapshot }
        switch snapshot?.summary.inputAvailability {
        case .openPrompt(let epoch), .localDraft(let epoch): currentBindingID = epoch.bindingID
        default:
            if let epoch = snapshot?.summary.inputControl?.turnEpoch ?? snapshot?.pendingInteractions.first?.inputEpoch {
                currentBindingID = epoch.bindingID
            }
        }
        recordDraftOwner()
        // A projection can invalidate an old cursor after a provider rebind.
        // Restart once, then let the next invalidation drive further work.
        for attempt in 0..<2 {
            switch service.events(for: id, after: cursor, limit: 500) {
            case .page(let page):
                events.append(contentsOf: page.events)
                if page.historyTruncated == true { historyTruncated = true }
                if events.count > 2_000 {
                    events.removeFirst(events.count - 2_000)
                    historyTruncated = true
                }
                cursor = page.continuationCursor ?? cursor
                if page.hasMore {
                    Task { @MainActor [weak self] in self?.refresh() }
                }
                reconcileAnswers()
                return
            case .resnapshotRequired where attempt == 0:
                cursor = nil
                events = []
            default: return
            }
        }
    }

    func send(steer: Bool = false) async {
        guard steer ? canSteer : canSend, let id = conversationID else { return }
        let text = draft
        let files = attachments
        let binding = currentBindingID
        let mode: RemoteMessageDeliveryMode
        let epoch: RemoteInputEpoch
        if let open = inputEpoch { mode = .prompt; epoch = open }
        else if let turn = snapshot?.summary.inputControl?.turnEpoch {
            mode = steer ? .steer : .queue
            epoch = turn
        } else { notice = "Input changed. Wait for the current session state."; return }
        let requestID: String
        if let previous = pendingSend, previous.conversationID == id,
           previous.text == text, previous.attachments == files {
            requestID = previous.requestID
        } else { requestID = UUID().uuidString }
        pendingSend = PendingSend(conversationID: id, text: text, attachments: files, requestID: requestID)
        sending = true
        defer { sending = false }
        let result = await sendMessage(.init(conversationID: id, clientRequestID: requestID,
            expectedInputEpoch: epoch, text: text, attachments: files, deliveryMode: mode))
        guard conversationID == id, currentBindingID == binding else {
            notice = "The session changed during delivery. Inspect the previous terminal before reusing this draft."
            return
        }
        switch result {
        case .accepted, .queued, .duplicate:
            if draft == text { draft = "" }
            attachments.removeAll { file in files.contains { $0.id == file.id } }
            pendingSend = nil
            if case .queued = result { notice = "Message queued." } else { notice = nil }
        case .uncertain:
            // Retain the request identity. An unchanged manual retry cannot inject twice.
            notice = "Delivery is uncertain. Inspect the terminal before sending this message again."
        case .rejected(let reason):
            pendingSend = nil
            notice = "Message was not sent: \(reason.rawValue.replacingOccurrences(of: "_", with: " "))."
        }
        refresh()
    }

    func interrupt() {
        guard let id = conversationID, let epoch = snapshot?.summary.inputControl?.turnEpoch else { return }
        switch service.interruptLocal(.init(conversationID: id, expectedTurnEpoch: epoch)) {
        case .accepted: notice = nil
        case .rejected(let reason): notice = "Could not stop: \(reason.rawValue.replacingOccurrences(of: "_", with: " "))."
        }
        refresh()
    }

    func updateQueue(_ action: RemoteConversationQueueAction, requestID: String? = nil) {
        guard let id = conversationID else { return }
        let result = service.updateLocalQueue(.init(conversationID: id, action: action, clientRequestID: requestID))
        notice = result == .conversationNotFound ? "This conversation is no longer available." : nil
        refresh()
    }

    struct DraftHold: Equatable {
        let conversationID: RemoteConversationID
        let epoch: RemoteInputEpoch
    }

    var draftHold: DraftHold? {
        guard let conversationID, case .localDraft(let epoch) = snapshot?.summary.inputAvailability else { return nil }
        return DraftHold(conversationID: conversationID, epoch: epoch)
    }

    func releaseTerminalDraft(expected hold: DraftHold) {
        guard draftHold == hold else {
            notice = "The terminal draft changed. Inspect it again before releasing its hold."
            return
        }
        switch service.releaseLocalDraft(.init(conversationID: hold.conversationID, expectedDraftEpoch: hold.epoch)) {
        case .released: notice = nil
        case .rejected: notice = "The terminal changed. Check its draft again."
        }
        refresh()
    }

    func editAnswer(_ edit: ConversationInteractionAnswerEdit, interaction: RemotePendingInteraction) {
        guard let current = snapshot?.pendingInteractions.first(where: { $0.id == interaction.id }),
              current.inputEpoch == interaction.inputEpoch, current.responseID == interaction.responseID,
              var state = answerStates[interaction.id] else { return }
        switch state.status {
        case .editing, .failed: break
        default: return
        }
        switch edit {
        case .toggleOption(let questionID, let optionID):
            var draft = state.drafts[questionID] ?? .init()
            if !draft.selectedOptionIDs.insert(optionID).inserted { draft.selectedOptionIDs.remove(optionID) }
            state.drafts[questionID] = draft
        case .selectOnly(let questionID, let optionID):
            state.drafts[questionID] = .init(selectedOptionIDs: [optionID])
        case .toggleCustomText(let questionID):
            var draft = state.drafts[questionID] ?? .init()
            draft.usesCustomText.toggle()
            if state.questions.first(where: { $0.id == questionID })?.multiSelect == false { draft.selectedOptionIDs = [] }
            state.drafts[questionID] = draft
        case .setCustomText(let questionID, let text):
            var draft = state.drafts[questionID] ?? .init()
            draft.customText = text
            state.drafts[questionID] = draft
        }
        state.status = .editing
        answerStates[interaction.id] = state
    }

    func answer(_ captured: RemotePendingInteraction) {
        guard let interaction = snapshot?.pendingInteractions.first(where: { $0.id == captured.id }),
              captured.inputEpoch == interaction.inputEpoch, captured.responseID == interaction.responseID,
              interaction.state == .pending,
              interaction.responseExpiresAt.map({ $0 > Date() }) != false,
              let id = conversationID, let responseID = interaction.responseID,
              var state = answerStates[interaction.id], state.canSubmit,
              let answers = state.canonicalAnswers else { return }
        let result = service.answerLocal(.init(conversationID: id, interactionID: interaction.id,
            responseID: responseID, expectedInputEpoch: interaction.inputEpoch,
            clientRequestID: UUID().uuidString, answers: answers))
        switch result {
        case .submitted, .duplicate:
            state.status = .awaitingClaude
            if interaction.kind == .permission { state.sentOptionID = answers.first?.selectedOptionIDs.first }
        case .rejected(let reason):
            let message = reason.rawValue.replacingOccurrences(of: "_", with: " ")
            state.status = reason == .invalidAnswers ? .failed(message) : .unavailable(message)
        }
        answerStates[interaction.id] = state
        refresh()
    }

    private func reconcileAnswers() {
        let pending = snapshot?.pendingInteractions ?? []
        let ids = Set(pending.map(\.id))
        answerStates = answerStates.filter { ids.contains($0.key) }
        answerBindings = answerBindings.filter { ids.contains($0.key) }
        for interaction in pending {
            guard let questions = interaction.questions else {
                answerStates.removeValue(forKey: interaction.id)
                answerBindings.removeValue(forKey: interaction.id)
                continue
            }
            let binding = AnswerBinding(epoch: interaction.inputEpoch, responseID: interaction.responseID)
            // Submission closes its response channel before the provider resolves
            // the question. Preserve the accepted answer through that interval.
            if answerStates[interaction.id]?.status == .awaitingClaude,
               answerBindings[interaction.id]?.epoch == binding.epoch,
               answerStates[interaction.id]?.questions == questions,
               interaction.responseID == nil || answerBindings[interaction.id] == binding { continue }
            if answerBindings[interaction.id] != binding || answerStates[interaction.id]?.questions != questions {
                answerStates[interaction.id] = .init(questions: questions)
                answerBindings[interaction.id] = binding
            }
            if interaction.state != .pending || interaction.responseID == nil
                || interaction.responseExpiresAt.map({ $0 <= Date() }) == true {
                answerStates[interaction.id]?.status = .unavailable("Respond in the terminal.")
            }
        }
    }
}
