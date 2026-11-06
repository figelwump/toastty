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

/// The parts of the app the New Task sheet talks to.
@MainActor
protocol ToasttyNewTaskHost: AnyObject {
    func taskCreateOptions() async -> ToasttyTaskCreateOptionsOutcome
    func createTask(_ request: RemoteTaskCreateRequest) async -> ToasttyTaskCreateOutcome
}

extension HomeScreenController: ToasttyNewTaskHost {}

/// Presentation state for the New Task sheet, which works like the Mac's
/// quick entry: the task text and files, a project, and an agent preset.
/// The Mac saves the task at once and runs its setup, so the sheet closes
/// as soon as the Mac answers.
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
    }

    static let unreachableMessage = "Couldn't reach your Mac. Your task is still here. Tap Create to try again."
    static let unrecognizedAnswerMessage = "Your Mac sent an answer this app doesn't understand. Check the Mac before you try again, and update Toastty Mobile."
    static let textTooLongMessage = "That task is too long to send. Shorten it and tap Create again."
    static let attachmentsTooLargeMessage = "That task and its attachments are too large to send. Shorten the task or remove a file, then tap Create again."
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

    @ObservationIgnored private let host: any ToasttyNewTaskHost
    @ObservationIgnored private let makeRequestID: () -> String
    /// A request the Mac did not answer. The Mac keeps each request ID with
    /// its task, so sending it again can never make a second task.
    @ObservationIgnored private var unconfirmedRequestID: String?
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

    var agentTitle: String {
        preset.map(Self.title) ?? "Choose"
    }

    /// The models to offer for `agent`: the one chosen now, then the Mac's
    /// suggestions. A value the Mac would refuse is left out.
    func modelChoices(for agent: RemoteSessionStartAgent) -> [String] {
        guard agent.supportsModel else { return [] }
        var seen = Set<String>()
        let current = preset?.profileID == agent.profileID ? preset?.model : nil
        return ([current].compactMap { $0 } + agent.recentModels)
            .filter { Self.isValidModel($0) && seen.insert($0).inserted }
    }

    /// A reason in the options that rules out any create.
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
        if options.workspaces.isEmpty {
            return "Toastty on your Mac has no project open. Open one there, then try again."
        }
        if agents.isEmpty {
            return "Your Mac has no agent that can take a task."
        }
        return nil
    }

    var canCreate: Bool {
        allowsEditing
            && isLoadingAttachments == false
            && blockingMessage == nil
            && workspaces.contains { $0.id == workspaceID }
            && selectedAgent != nil
            && trimmedText.isEmpty == false
            && (attachments.isEmpty || supportsAttachments)
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
        text.isEmpty == false || attachments.isEmpty == false || isLoadingAttachments || phase == .creating
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

    /// Starts on the Mac's quick entry choices: its last workspace and
    /// preset, else the first of each.
    private func apply(_ response: RemoteTaskCreateOptionsResponse) {
        options = response
        if workspaces.contains(where: { $0.id == workspaceID }) == false {
            workspaceID = response.defaultWorkspaceID.flatMap { id in workspaces.contains { $0.id == id } ? id : nil }
                ?? workspaces.first?.id
        }
        if preset.map(isUsable) != true {
            preset = response.defaultPreset.flatMap { isUsable($0) ? $0 : nil }
                ?? frequentPresets.first
                ?? agents.first.map { RemoteTaskPreset(profileID: $0.profileID) }
        }
    }

    // MARK: - Editing

    func selectWorkspace(_ id: UUID) {
        guard allowsEditing, id != workspaceID, workspaces.contains(where: { $0.id == id }) else { return }
        workspaceID = id
        draftDidChange()
    }

    func selectPreset(_ newPreset: RemoteTaskPreset) {
        guard allowsEditing, newPreset != preset, isUsable(newPreset) else { return }
        preset = newPreset
        draftDidChange()
    }

    /// Picks a model for `agent`. Switching agents keeps an effort only
    /// when the new agent takes it.
    func selectModel(_ model: String?, for agent: RemoteSessionStartAgent) {
        let effort = preset?.effort.flatMap { agent.reasoningEfforts.contains($0) ? $0 : nil }
        selectPreset(RemoteTaskPreset(profileID: agent.profileID, model: agent.supportsModel ? model : nil, effort: effort))
    }

    func selectEffort(_ effort: String?, for agent: RemoteSessionStartAgent) {
        let model = preset?.profileID == agent.profileID ? preset?.model : nil
        selectPreset(RemoteTaskPreset(profileID: agent.profileID, model: model, effort: effort))
    }

    /// Uses a typed model ID. Returns false, and says why, when the Mac
    /// would refuse it.
    @discardableResult
    func useCustomModel(_ value: String, for agent: RemoteSessionStartAgent) -> Bool {
        guard allowsEditing else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidModel(trimmed) else {
            errorMessage = Self.invalidModelMessage
            return false
        }
        selectModel(trimmed, for: agent)
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
        guard phase != .creating else { return }
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
            // Nothing was saved, so the next create is a new request.
            unconfirmedRequestID = nil
            errorMessage = Self.message(for: reason, macMessage: message, agentName: agent.displayName)
            phase = .form
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

    // MARK: - Helpers

    /// Any edit makes a different request, which needs its own key.
    private func draftDidChange() {
        unconfirmedRequestID = nil
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
