import Foundation
import Observation
import RemoteProtocol
import ToasttyMobileDomain

/// What the phone learned from asking the Mac what a new task can use.
enum ToasttyTaskCreateOptionsOutcome: Equatable, Sendable {
    case loaded(RemoteTaskCreateOptionsResponse)
    /// The request failed or was never sent.
    case unreachable
}

/// What the phone learned from asking the Mac to create a task.
enum ToasttyTaskCreateOutcome: Equatable, Sendable {
    case answered(RemoteTaskCreateResult)
    /// No answer: the request failed on the way or was never sent. The Mac
    /// may still have saved the task, so a retry must reuse the same
    /// request ID.
    case unconfirmed
}

/// What the phone learned from asking the Mac to send a message to the
/// coordinator.
enum ToasttyCoordinatorSendOutcome: Equatable, Sendable {
    case answered(RemoteCoordinatorSendResult)
    /// No answer: the request failed on the way or was never sent. The Mac
    /// may still have the message, so a retry must reuse the same request
    /// ID.
    case unconfirmed
}

/// The parts of the app the New Task sheet talks to.
@MainActor
protocol ToasttyNewTaskHost: AnyObject {
    /// The Mac takes messages for its coordinator from this device. The
    /// create options then say whether it has a coordinator now.
    var supportsCoordinatorSend: Bool { get }
    func taskCreateOptions() async -> ToasttyTaskCreateOptionsOutcome
    func createTask(_ request: RemoteTaskCreateRequest) async -> ToasttyTaskCreateOutcome
    func sendToCoordinator(_ request: RemoteCoordinatorSendRequest) async -> ToasttyCoordinatorSendOutcome
}

extension HomeScreenController: ToasttyNewTaskHost {}

/// Presentation state for the New Task sheet, which works like the Mac's
/// quick entry: the task text and files, a project, and an agent preset.
/// The Mac saves the task at once and runs its setup, so the sheet closes
/// as soon as the Mac answers.
///
/// While the Mac has a coordinator and takes messages for it, the sheet
/// sends to it, as the Mac's panel does: Send is the action, the
/// Workspace and Agent pills start as Auto and leave the choice to the
/// coordinator, and a pill the user sets goes with the message as their
/// choice. Once the user sets both pills, the action becomes Create, which
/// makes the task directly. A value the user did not choose is never used
/// for a create.
@MainActor
@Observable
final class ToasttyNewTaskModel: Identifiable {
    enum Phase: Equatable {
        case loading
        /// The options could not be loaded.
        case unreachable
        case form
        /// A create request is on its way.
        case creating
        /// The Mac saved the task.
        case created
        /// A message for the coordinator is on its way.
        case sending
        /// The coordinator has the message, or the Mac keeps it until the
        /// coordinator's prompt takes it.
        case sent(RemoteCoordinatorSendResult)
    }

    static let unreachableMessage = "Couldn't reach your Mac. Your task is still here. Tap Create to try again."
    static let sendUnreachableMessage = "Couldn't reach your Mac. Your message is still here. Tap Send to try again."
    static let unrecognizedSendAnswerMessage = "Your Mac sent an answer this app doesn't understand. Check the coordinator on the Mac before you send again, and update Toastty Mobile."
    static let autoTitle = "Auto"
    static let unrecognizedAnswerMessage = "Your Mac sent an answer this app doesn't understand. Check the Mac before you try again, and update Toastty Mobile."
    static let textTooLongMessage = "That task is too long to send. Shorten it and try again."
    static let attachmentsTooLargeMessage = "That task and its attachments are too large to send. Shorten the task or remove a file, then try again."
    static let attachmentsUnsupportedMessage = "Update Toastty on your Mac to attach files."
    static let invalidModelMessage = "That isn't a model ID the Mac can use. Use one word with no spaces that doesn't start with a dash."

    let id = UUID()
    private(set) var phase: Phase = .loading
    private(set) var options: RemoteTaskCreateOptionsResponse?
    private(set) var workspaceID: UUID?
    /// The agent, model and effort. `nil` only while no agent is offered.
    private(set) var preset: RemoteTaskPreset?
    private(set) var text = ""
    /// File bytes stay in this sheet's draft.
    private(set) var attachments: [RemoteMessageAttachment] = []
    private(set) var isLoadingAttachments = false
    /// Why the last create or edit did not work. Cleared by any edit.
    private(set) var errorMessage: String?
    /// The form is asking the Mac for its options again.
    private(set) var isReloadingOptions = false
    /// The coordinator, while the Mac has one and takes messages for it
    /// from this device. The sheet then sends to it.
    private(set) var coordinator: RemoteCoordinatorSendState?
    /// The user set the Workspace pill in this sheet. Only then does a
    /// message for the coordinator name the project as the user's choice.
    private(set) var choseWorkspace = false
    /// The user set the agent, model or effort in this sheet.
    private(set) var chosePreset = false

    @ObservationIgnored private let host: any ToasttyNewTaskHost
    @ObservationIgnored private let makeRequestID: () -> String
    /// The request ID of this unchanged draft, once sent. The Mac keeps each
    /// request ID with its task, so sending it again can never make a
    /// second task. Only an edit or a created task clears it: a refusal
    /// can follow an attempt whose answer was lost after the Mac saved it.
    @ObservationIgnored private var unconfirmedRequestID: String?
    /// The request ID of this unchanged draft's message for the
    /// coordinator, once sent, with the same rules as
    /// `unconfirmedRequestID`. The Mac answers a repeat with the first
    /// result and sends nothing new.
    @ObservationIgnored private var unconfirmedSendRequestID: String?
    /// The workspace and preset the pills started on. A pill set back to
    /// Auto goes back to them.
    @ObservationIgnored private var startingWorkspaceID: UUID?
    @ObservationIgnored private var startingPreset: RemoteTaskPreset?
    /// Late import or options answers must not restore a canceled draft.
    @ObservationIgnored private var isDiscarded = false

    /// `text`, `attachments`, and `notice` start the draft with content
    /// shared from another app. The Mac's limits still apply at Create.
    init(
        host: any ToasttyNewTaskHost,
        text: String = "",
        attachments: [RemoteMessageAttachment] = [],
        notice: String? = nil,
        makeRequestID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.host = host
        self.text = text
        self.attachments = attachments
        self.makeRequestID = makeRequestID
        errorMessage = notice
    }

    // MARK: - Derived presentation

    /// The Mac has a coordinator that takes this sheet's messages.
    var sendsToCoordinator: Bool {
        coordinator != nil
    }

    /// The sheet's one action makes the task on the Mac, without the
    /// coordinator: there is no coordinator, or the user set both the
    /// Workspace and the Agent pill. While a pill shows Auto, the action
    /// is Send and the coordinator chooses.
    var createsDirectly: Bool {
        sendsToCoordinator == false || (choseWorkspace && chosePreset)
    }

    /// The coordinator chooses the project: the user has not set the
    /// Workspace pill.
    var workspaceIsAuto: Bool {
        sendsToCoordinator && choseWorkspace == false
    }

    /// The coordinator chooses the agent, model and effort.
    var agentIsAuto: Bool {
        sendsToCoordinator && chosePreset == false
    }

    /// The Workspace pill's value: with a coordinator, Auto until the user
    /// sets it.
    var workspacePillTitle: String {
        workspaceIsAuto ? Self.autoTitle : workspaceTitle
    }

    /// The Agent pill's value: with a coordinator, Auto until the user sets
    /// it. Model and Effort show only once an agent is chosen.
    var agentPillTitle: String {
        agentIsAuto ? Self.autoTitle : agentTitle
    }

    var showsModelAndEffort: Bool {
        agentIsAuto == false
    }

    /// One line before a send when the message will wait, as the Mac's
    /// panel says it in its header.
    var coordinatorNote: String? {
        // Create makes the task on the Mac; nothing waits for the coordinator.
        guard let coordinator, createsDirectly == false else { return nil }
        switch coordinator.agent {
        case .notRunning:
            return "The coordinator is not running. Your message waits on your Mac until it starts."
        case .starting:
            return "The coordinator is starting. Your message waits on your Mac until it is ready."
        case .running, .unknown:
            switch coordinator.waitingCount {
            case 0: return nil
            case 1: return "1 message waits for the coordinator."
            case let count: return "\(count) messages wait for the coordinator."
            }
        }
    }

    /// Whether the note says that a sent message will wait.
    var coordinatorNoteIsWarning: Bool {
        coordinator?.agent == .notRunning || coordinator?.agent == .starting
    }

    var workspaces: [RemoteTaskCreateWorkspace] {
        options?.workspaces ?? []
    }

    var workspaceTitle: String {
        workspaces.first { $0.id == workspaceID }?.title ?? "Choose"
    }

    var agents: [RemoteSessionStartAgent] {
        (options?.agents ?? []).filter { $0.availability == .available }
    }

    var selectedAgent: RemoteSessionStartAgent? {
        agents.first { $0.profileID == preset?.profileID }
    }

    /// The Mac's Frequent presets that this phone can send as they are.
    var frequentPresets: [RemoteTaskPreset] {
        (options?.frequentPresets ?? []).filter(isUsable)
    }

    /// The Agent, Model and Effort pills' values, as the Mac's Agent picker
    /// columns show them. A nil model or effort is the profile's default.
    var agentTitle: String {
        selectedAgent?.displayName ?? "Choose"
    }

    var modelTitle: String {
        preset?.model.map(Self.shortModelName) ?? Self.defaultChoiceTitle
    }

    var effortTitle: String {
        preset?.effort ?? Self.defaultChoiceTitle
    }

    static let defaultChoiceTitle = "Default"

    /// The selected agent's models: the Mac's suggestions in their order,
    /// with a typed model the list lacks first. A value the Mac would
    /// refuse is left out.
    var modelChoices: [String] {
        guard let agent = selectedAgent, agent.supportsModel else { return [] }
        var seen = Set<String>()
        let typed = preset?.model.flatMap { agent.recentModels.contains($0) ? nil : $0 }
        return ([typed].compactMap { $0 } + agent.recentModels)
            .filter { Self.isValidModel($0) && seen.insert($0).inserted }
    }

    /// A reason in the options that rules out any create. With a
    /// coordinator, only a missing permission rules out a send: the
    /// coordinator can answer without a project or an agent.
    var blockingMessage: String? {
        guard let options else { return nil }
        switch options.permission {
        case .allowed:
            break
        case .startDisabled:
            return "Starting sessions was turned off for this iPhone, and a task starts one. Turn it back on in Toastty → Settings → Remote Access on your Mac."
        case .sendDisabled:
            return "This iPhone can't send messages, and a task starts an agent with one. Turn on sending in Toastty → Settings → Remote Access on your Mac."
        case .unknown:
            return "Your Mac isn't accepting new tasks from this iPhone right now."
        }
        if sendsToCoordinator { return nil }
        if options.workspaces.isEmpty {
            return "Toastty on your Mac has no project open. Open one there, then try again."
        }
        if agents.isEmpty {
            return "Your Mac has no agent that can take a task."
        }
        return nil
    }

    var canCreate: Bool {
        createsDirectly
            && canSubmitDraft
            && workspaces.contains { $0.id == workspaceID }
            && selectedAgent != nil
    }

    var canSend: Bool {
        sendsToCoordinator && createsDirectly == false && canSubmitDraft
    }

    /// The draft and the options allow a send or a create.
    private var canSubmitDraft: Bool {
        allowsEditing
            && isLoadingAttachments == false
            && isReloadingOptions == false
            && blockingMessage == nil
            && trimmedText.isEmpty == false
            && (attachments.isEmpty || supportsAttachments)
    }

    /// A send or a create is on its way.
    var isSubmitting: Bool {
        phase == .creating || phase == .sending
    }

    var supportsAttachments: Bool {
        options?.supportsAttachments == true
    }

    var allowsAttachmentInput: Bool {
        allowsEditing
    }

    var allowsEditing: Bool {
        phase == .form && isDiscarded == false
    }

    var preventsInteractiveDismissal: Bool {
        text.isEmpty == false || attachments.isEmpty == false || isLoadingAttachments || isSubmitting
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Loading

    func loadOptions() async {
        guard isDiscarded == false, phase == .loading || phase == .unreachable else { return }
        phase = .loading
        let outcome = await host.taskCreateOptions()
        guard isDiscarded == false else { return }
        switch outcome {
        case .loaded(let response):
            apply(response)
            phase = .form
        case .unreachable:
            phase = .unreachable
        }
    }

    /// Asks the Mac again, as after opening a project there, and keeps the
    /// draft and any choice that is still offered.
    func reloadOptions() async {
        guard allowsEditing, isReloadingOptions == false else { return }
        isReloadingOptions = true
        let outcome = await host.taskCreateOptions()
        isReloadingOptions = false
        guard allowsEditing else { return }
        switch outcome {
        case .loaded(let response):
            apply(response)
            if errorMessage == Self.unreachableMessage || errorMessage == Self.sendUnreachableMessage {
                errorMessage = nil
            }
        case .unreachable:
            // Name the button the sheet shows now.
            errorMessage = createsDirectly ? Self.unreachableMessage : Self.sendUnreachableMessage
        }
    }

    /// Starts on the Mac's quick entry choices: its last workspace and
    /// preset, else the first of each. A choice the Mac no longer offers
    /// goes back to Auto.
    private func apply(_ response: RemoteTaskCreateOptionsResponse) {
        options = response
        coordinator = host.supportsCoordinatorSend ? response.coordinator : nil
        if workspaces.contains(where: { $0.id == workspaceID }) == false {
            workspaceID = response.defaultWorkspaceID.flatMap { id in workspaces.contains { $0.id == id } ? id : nil }
                ?? workspaces.first?.id
            startingWorkspaceID = workspaceID
            choseWorkspace = false
        }
        if preset.map(isUsable) != true {
            preset = response.defaultPreset.flatMap { isUsable($0) ? $0 : nil }
                ?? frequentPresets.first
                ?? agents.first.map { RemoteTaskPreset(profileID: $0.profileID) }
            startingPreset = preset
            chosePreset = false
        }
    }

    // MARK: - Editing

    func selectWorkspace(_ id: UUID) {
        // From Auto, the value the pill started on is a choice too.
        guard allowsEditing, id != workspaceID || workspaceIsAuto,
              workspaces.contains(where: { $0.id == id }) else { return }
        workspaceID = id
        choseWorkspace = true
        draftDidChange()
    }

    /// Leaves the project to the coordinator. The pill's menu marks the
    /// workspace the sheet started on again.
    func selectAutoWorkspace() {
        guard allowsEditing, sendsToCoordinator, choseWorkspace else { return }
        choseWorkspace = false
        workspaceID = startingWorkspaceID.flatMap { id in workspaces.contains { $0.id == id } ? id : nil }
            ?? workspaces.first?.id
        draftDidChange()
    }

    func selectPreset(_ newPreset: RemoteTaskPreset) {
        guard allowsEditing, newPreset != preset || agentIsAuto, isUsable(newPreset) else { return }
        preset = newPreset
        chosePreset = true
        draftDidChange()
    }

    /// Leaves the agent, model and effort to the coordinator. The pills
    /// go back to the preset the sheet started on.
    func selectAutoAgent() {
        guard allowsEditing, sendsToCoordinator, chosePreset else { return }
        chosePreset = false
        preset = startingPreset.flatMap { isUsable($0) ? $0 : nil }
            ?? frequentPresets.first
            ?? agents.first.map { RemoteTaskPreset(profileID: $0.profileID) }
        draftDidChange()
    }

    /// Switches the agent as the Mac's Agent column does: a model or effort
    /// the new agent does not list goes back to Default. An agent chosen
    /// from Auto starts on Default: only what the user sets goes to the
    /// coordinator as their choice.
    func selectAgent(_ agent: RemoteSessionStartAgent) {
        guard agent.profileID != preset?.profileID || agentIsAuto else { return }
        let current = agentIsAuto ? nil : preset
        let model = current?.model.flatMap { agent.supportsModel && agent.recentModels.contains($0) ? $0 : nil }
        let effort = current?.effort.flatMap { agent.reasoningEfforts.contains($0) ? $0 : nil }
        selectPreset(RemoteTaskPreset(profileID: agent.profileID, model: model, effort: effort))
    }

    /// Sets the selected agent's model; `nil` is its default.
    func selectModel(_ model: String?) {
        guard let current = preset else { return }
        selectPreset(RemoteTaskPreset(profileID: current.profileID, model: model, effort: current.effort))
    }

    /// Sets the selected agent's effort; `nil` is its default.
    func selectEffort(_ effort: String?) {
        guard let current = preset else { return }
        selectPreset(RemoteTaskPreset(profileID: current.profileID, model: current.model, effort: effort))
    }

    /// Uses a typed model ID for `profileID`, the agent the prompt opened
    /// for. Returns false when that agent is no longer selected, as after
    /// a reload, and says why when the Mac would refuse the ID.
    @discardableResult
    func useCustomModel(_ value: String, for profileID: String) -> Bool {
        guard allowsEditing, preset?.profileID == profileID else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidModel(trimmed) else {
            errorMessage = Self.invalidModelMessage
            return false
        }
        selectModel(trimmed)
        return true
    }

    func updateText(_ newText: String) {
        guard allowsEditing, newText != text else { return }
        text = newText
        draftDidChange()
    }

    /// The picker sets this before reading files so Create cannot overtake it.
    func setIsLoadingAttachments(_ isLoading: Bool) {
        guard isLoading == false || (allowsAttachmentInput && supportsAttachments) else { return }
        isLoadingAttachments = isLoading
    }

    @discardableResult
    func addAttachments(_ additions: [RemoteMessageAttachment]) -> String? {
        guard allowsAttachmentInput, isLoadingAttachments == false else {
            return "Wait until the attachment and task options are ready."
        }
        guard supportsAttachments else { return Self.attachmentsUnsupportedMessage }
        guard additions.isEmpty == false else { return nil }
        let updated = attachments + additions
        if let error = RemoteAttachmentPolicy.validationError(for: updated) { return error }
        attachments = updated
        draftDidChange()
        return nil
    }

    func removeAttachment(_ id: UUID) {
        guard allowsEditing, isLoadingAttachments == false,
              attachments.contains(where: { $0.id == id }) else { return }
        attachments.removeAll { $0.id == id }
        draftDidChange()
    }

    func discardDraft() {
        guard isSubmitting == false else { return }
        isDiscarded = true
        text = ""
        attachments = []
        isLoadingAttachments = false
        draftDidChange()
    }

    // MARK: - Creating

    func create() async {
        guard canCreate, let workspaceID, let agent = selectedAgent, let preset else { return }
        let requestID = unconfirmedRequestID ?? makeRequestID()
        let request = RemoteTaskCreateRequest(
            clientRequestID: requestID,
            workspaceID: workspaceID,
            profileID: agent.profileID,
            model: agent.supportsModel ? preset.model : nil,
            effort: preset.effort.flatMap { agent.reasoningEfforts.contains($0) ? $0 : nil },
            text: trimmedText,
            attachments: attachments
        )
        // The Mac refuses a larger request before it reads it. Sending one
        // would look like a lost connection that Create could never fix.
        guard request.text.utf8.count <= RemoteGatewayProtocol.maximumRequestBodyBytes else {
            errorMessage = Self.textTooLongMessage
            return
        }
        if let error = RemoteAttachmentPolicy.validationError(for: request.attachments) {
            errorMessage = error
            return
        }
        let maximumBodyBytes = attachments.isEmpty
            ? RemoteGatewayProtocol.maximumRequestBodyBytes
            : RemoteAttachmentPolicy.maximumEncodedBodyBytes
        guard let encoded = try? request.encodedForTransport(), encoded.count <= maximumBodyBytes else {
            errorMessage = attachments.isEmpty ? Self.textTooLongMessage : Self.attachmentsTooLargeMessage
            return
        }
        unconfirmedRequestID = requestID
        errorMessage = nil
        phase = .creating

        switch await host.createTask(request) {
        case .answered(.created):
            unconfirmedRequestID = nil
            phase = .created
        case .answered(.rejected(let reason, let message)):
            // This attempt saved nothing, but an earlier one with the same
            // ID may have, so the unchanged draft keeps its ID.
            errorMessage = Self.message(for: reason, macMessage: message, agentName: agent.displayName)
            phase = .form
            // The pickers may list a project or agent the Mac no longer has.
            if reason == .workspaceNotFound || reason == .agentUnavailable {
                await reloadOptions()
            }
        case .answered(.unrecognized):
            // The Mac's answer could mean the task was saved. Keep the
            // request ID, so another Create cannot make a second one.
            errorMessage = Self.unrecognizedAnswerMessage
            phase = .form
        case .unconfirmed:
            errorMessage = Self.unreachableMessage
            phase = .form
        }
    }

    // MARK: - Sending to the coordinator

    /// Sends the text and files to the coordinator as a quick entry
    /// message, with the pills the user set as their choices.
    func send() async {
        guard canSend else { return }
        let agent = chosePreset ? selectedAgent : nil
        let chosen = agent == nil ? nil : preset
        let requestID = unconfirmedSendRequestID ?? makeRequestID()
        let request = RemoteCoordinatorSendRequest(
            clientRequestID: requestID,
            workspaceID: choseWorkspace ? workspaceID : nil,
            profileID: agent?.profileID,
            model: agent?.supportsModel == true ? chosen?.model : nil,
            effort: chosen?.effort.flatMap { agent?.reasoningEfforts.contains($0) == true ? $0 : nil },
            text: trimmedText,
            attachments: attachments
        )
        // The Mac refuses a larger request before it reads it.
        guard request.text.utf8.count <= RemoteGatewayProtocol.maximumRequestBodyBytes else {
            errorMessage = Self.textTooLongMessage
            return
        }
        if let error = RemoteAttachmentPolicy.validationError(for: request.attachments) {
            errorMessage = error
            return
        }
        let maximumBodyBytes = attachments.isEmpty
            ? RemoteGatewayProtocol.maximumRequestBodyBytes
            : RemoteAttachmentPolicy.maximumEncodedBodyBytes
        guard let encoded = try? request.encodedForTransport(), encoded.count <= maximumBodyBytes else {
            errorMessage = attachments.isEmpty ? Self.textTooLongMessage : Self.attachmentsTooLargeMessage
            return
        }
        unconfirmedSendRequestID = requestID
        errorMessage = nil
        phase = .sending

        switch await host.sendToCoordinator(request) {
        case .answered(let result):
            switch result {
            case .sent, .waiting:
                unconfirmedSendRequestID = nil
                phase = .sent(result)
            case .rejected(let reason, let message):
                // This attempt sent nothing, but an earlier one with the
                // same ID may have, so the unchanged draft keeps its ID.
                errorMessage = Self.message(for: reason, macMessage: message, agentName: agent?.displayName)
                phase = .form
                // The coordinator closed, or the pickers list a project or
                // agent the Mac no longer has. Without a coordinator the
                // sheet creates the task directly.
                if reason == .noCoordinator || reason == .workspaceNotFound || reason == .agentUnavailable {
                    await reloadOptions()
                }
            case .unrecognized:
                errorMessage = Self.unrecognizedSendAnswerMessage
                phase = .form
            }
        case .unconfirmed:
            errorMessage = Self.sendUnreachableMessage
            phase = .form
        }
    }

    /// What the screen that opened the sheet says after a send, as the
    /// Mac's quick entry toast says it.
    static func sentNotice(_ result: RemoteCoordinatorSendResult) -> String {
        switch result {
        case .sent:
            "Sent to the coordinator"
        case .waiting(let reason):
            switch reason {
            case .notRunning: "Waits on your Mac: the coordinator is not running"
            case .starting: "Waits on your Mac: the coordinator is starting"
            case .working: "Waits on your Mac: the coordinator is working"
            case .userDraft: "Waits on your Mac: text is in the coordinator's terminal"
            case .promptNotOpen: "Waits on your Mac for the coordinator's prompt"
            case .notSaved: "Waits on your Mac: Toastty could not save it"
            case .unknown: "Waits on your Mac for the coordinator"
            }
        case .rejected, .unrecognized:
            "The coordinator didn't get the message"
        }
    }

    static func message(
        for reason: RemoteCoordinatorSendRejectionReason,
        macMessage: String?,
        agentName: String?
    ) -> String {
        switch reason {
        case .permissionDenied:
            "Your Mac didn't let this iPhone send to the coordinator. Check Toastty → Settings → Remote Access on your Mac."
        case .noCoordinator:
            "Your Mac has no coordinator now. Nothing was sent. Tap Create to make the task yourself."
        case .workspaceNotFound:
            "That project is no longer open in Toastty on your Mac. Choose another one, or Auto."
        case .agentUnavailable:
            "\(agentName ?? "That agent") can't take a task on your Mac. Choose another agent, or Auto."
        case .invalidRequest:
            "Your Mac couldn't use this message. Check the model and effort, then try again."
        case .invalidAttachments:
            "Your Mac couldn't use an attachment. Remove it and choose an image, PDF, or supported text file."
        case .attachmentStorageUnavailable:
            "Your Mac couldn't save the attachments. Check its available disk space, then try again."
        case .sendFailed:
            macMessage.map { "The coordinator didn't take the message: \($0)" }
                ?? "The coordinator didn't take the message. Check Toastty on your Mac, then try again."
        case .busy:
            "Your Mac is still sending another message from this iPhone. Try again in a moment."
        case .unknown:
            "Your Mac didn't send the message. Try again."
        }
    }

    // MARK: - Helpers

    /// Any edit makes a different request, which needs its own key.
    private func draftDidChange() {
        unconfirmedRequestID = nil
        unconfirmedSendRequestID = nil
        errorMessage = nil
    }

    /// A preset whose agent is offered and takes its model and effort.
    private func isUsable(_ preset: RemoteTaskPreset) -> Bool {
        guard let agent = agents.first(where: { $0.profileID == preset.profileID }) else { return false }
        if let model = preset.model, agent.supportsModel == false || Self.isValidModel(model) == false { return false }
        if let effort = preset.effort, agent.reasoningEfforts.contains(effort) == false { return false }
        return true
    }

    private static func isValidModel(_ value: String) -> Bool {
        RemoteSessionStartPolicy.isValidSelectionValue(value, maximumLength: RemoteSessionStartPolicy.maximumModelLength)
    }

    /// "codex · gpt-6.1-sol · high", with a Claude model's short name as
    /// the Mac's quick entry shows it.
    static func title(_ preset: RemoteTaskPreset) -> String {
        [preset.profileID, preset.model.map(shortModelName), preset.effort]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The Mac's quick entry rule: a Claude ID drops "claude-" and any
    /// snapshot date, and its version takes a dot, so claude-opus-5-5 shows
    /// as opus-5.5. Other IDs, such as gpt-6.1-sol, show whole.
    static func shortModelName(_ model: String) -> String {
        guard let match = model.wholeMatch(
            of: #/claude-([a-z]+)-(\d+)(?:-(\d{1,2})(?!\d))?(?:-\d{8})?(.*)/#
        ) else { return model }
        let (_, family, major, minor, rest) = match.output
        return "\(family)-\(major)\(minor.map { ".\($0)" } ?? "")\(rest)"
    }

    static func message(
        for reason: RemoteTaskCreateRejectionReason,
        macMessage: String?,
        agentName: String
    ) -> String {
        switch reason {
        case .permissionDenied:
            "Your Mac didn't let this iPhone create a task. Check Toastty → Settings → Remote Access on your Mac."
        case .workspaceNotFound:
            "That project is no longer open in Toastty on your Mac. Choose another one."
        case .agentUnavailable:
            "\(agentName) can't take a task on your Mac. Choose another agent."
        case .invalidRequest:
            "Your Mac couldn't use this request. Check the model and effort, then try again."
        case .invalidAttachments:
            "Your Mac couldn't use an attachment. Remove it and choose an image, PDF, or supported text file."
        case .attachmentStorageUnavailable:
            "Your Mac couldn't save the attachments. Check its available disk space, then try again."
        case .createFailed:
            macMessage.map { "Your Mac couldn't create the task: \($0)" }
                ?? "Your Mac couldn't create the task. Check Toastty on your Mac, then try again."
        case .busy:
            "Your Mac is still saving another task from this iPhone. Try again in a moment."
        case .unknown:
            "Your Mac didn't create the task. Try again."
        }
    }
}
