import AppKit
import Combine
import CoreState
import Foundation

/// What an opener fills in before the quick entry panel shows.
struct QuickEntryPrefill: Equatable {
    /// Chooses the workspace; nil keeps the one the panel starts on.
    var workspaceID: UUID?
    /// Text selected in a terminal. It is attached as a text file, so the
    /// task text stays what the user types.
    var selectionText: String?

    static let empty = QuickEntryPrefill()
}

/// The coordinator, as the quick entry panel uses it. While a coordinator
/// exists, the panel sends to it and the pills are optional.
struct QuickEntryCoordinator {
    /// One line for the panel's header when the message will wait, such as
    /// "Coordinator is not running · your message waits".
    var hint: String?
    /// The project selected in Toastty when the panel opened. It goes with
    /// the message as a hint, not as the user's choice.
    var selectedProject: CoordinatorMessageHeader.Workspace?
    var send: @MainActor (CoordinatorUserMessage) async throws -> CoordinatorController.SendResult
}

/// The quick entry panel's state: the text, the attached files, and the
/// workspace and agent preset the task needs. Toastty copies each attached file into a
/// staging directory as soon as it is added, because a dragged screenshot
/// or a pasted image may live only in a temporary file.
///
/// With a coordinator, the panel sends the text to it. The workspace and
/// the preset are then choices the user can make or leave to the
/// coordinator, and a second key creates the task directly, as the panel
/// does without a coordinator.
@MainActor
final class QuickEntryModel: ObservableObject {
    typealias Attachment = DraftAttachments.Attachment

    struct Option: Identifiable, Equatable {
        let id: String
        let title: String
    }

    @Published var text = ""
    /// The attached files. Their changes are the panel's changes.
    let attachmentDraft: DraftAttachments
    var attachments: [Attachment] { attachmentDraft.attachments }
    /// nil until the user chooses one, when no workspace is selected in
    /// Toastty and none was used before. Create Task waits for it.
    @Published var workspaceID: UUID?
    /// The agent, model and effort. nil only when no Frequent preset or
    /// `[defaults]` agent is offered; Create Task waits for a choice.
    @Published var preset: QuickEntryPreset?
    /// The user set the Workspace pill in this panel. Only then does a
    /// message for the coordinator name the project as the user's choice.
    @Published private(set) var choseWorkspace = false
    /// The user set the Agent pill in this panel.
    @Published private(set) var chosePreset = false
    /// Set while a coordinator exists: the panel then sends to it.
    private(set) var coordinator: QuickEntryCoordinator?
    /// The workspace and the preset the panel started on. A pill that is
    /// set back to Auto goes back to them, for a direct create.
    private var startingWorkspaceID: UUID?
    private var startingPreset: QuickEntryPreset?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSubmitting = false
    /// Files still being copied in.
    var pendingAttachmentCount: Int { attachmentDraft.pendingCount }
    /// Bumped to ask the text editor to take focus.
    @Published private(set) var focusRequestID = 0
    /// A drag with files or images is over the panel.
    var isDropTargeted: Bool {
        get { attachmentDraft.isDropTargeted }
        set { attachmentDraft.isDropTargeted = newValue }
    }
    /// The pill whose picker is open.
    @Published var openPicker: QuickEntryPickerKind?
    /// Where each pill is, in the panel's top-left coordinates, so its
    /// picker opens under it.
    var pillFrames: [QuickEntryPickerKind: CGRect] = [:]

    @Published var workspaceOptions: [Option]
    var agentProfiles: [QuickEntryAgentProfile]
    /// Presets listed first in the Agent picker.
    let frequentPresets: [QuickEntryPreset]

    private let create: @MainActor (TaskCreateRequest) async throws -> TaskRecord
    private let onCreated: @MainActor (TaskRecord) -> Void
    private let onSent: @MainActor (CoordinatorController.SendResult) -> Void
    private let onCancel: @MainActor () -> Void
    /// One per panel, so a double submit or a retry after a lost answer
    /// returns the first task.
    private let clientRequestID = "quick-entry-\(UUID().uuidString)"
    /// One per panel, as `clientRequestID`: a message's files are copied
    /// under this ID.
    private let coordinatorMessageID = UUID()
    private var attachmentChanges: AnyCancellable?

    init(
        prefill: QuickEntryPrefill,
        preset: QuickEntryPreset? = nil,
        workspaceOptions: [Option],
        agentProfiles: [QuickEntryAgentProfile],
        frequentPresets: [QuickEntryPreset],
        stagingDirectoryURL: URL,
        coordinator: QuickEntryCoordinator? = nil,
        create: @escaping @MainActor (TaskCreateRequest) async throws -> TaskRecord,
        onCreated: @escaping @MainActor (TaskRecord) -> Void,
        onSent: @escaping @MainActor (CoordinatorController.SendResult) -> Void = { _ in },
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.workspaceOptions = workspaceOptions
        self.agentProfiles = agentProfiles
        self.frequentPresets = frequentPresets
        attachmentDraft = DraftAttachments(stagingDirectoryURL: stagingDirectoryURL)
        self.coordinator = coordinator
        self.create = create
        self.onCreated = onCreated
        self.onSent = onSent
        self.onCancel = onCancel
        self.preset = preset
        startingPreset = preset
        attachmentDraft.isEditable = { [weak self] in self?.isSubmitting == false }
        attachmentDraft.onError = { [weak self] message in self?.errorMessage = message }
        attachmentDraft.onLink = { [weak self] link in self?.appendLine(link) }
        attachmentChanges = attachmentDraft.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        apply(prefill)
    }

    /// True once the panel has closed. Copies still running then throw
    /// their file away, and the last one removes the staging folder.
    var isClosed: Bool { attachmentDraft.isClosed }

    /// False while a task is being created from this draft, so what the
    /// user sees is what gets saved.
    var isEditable: Bool {
        isSubmitting == false && isClosed == false
    }

    /// The panel sends to the coordinator; Create Task is the second key.
    var sendsToCoordinator: Bool { coordinator != nil }

    private var hasDraft: Bool {
        isEditable
            && pendingAttachmentCount == 0
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Whether ⌘↩ can act: send to the coordinator, or without one create
    /// the task.
    var canSubmit: Bool {
        hasDraft && (sendsToCoordinator || missingChoiceHint == nil)
    }

    /// Whether the task can be created directly.
    var canCreateTask: Bool {
        hasDraft && missingChoiceHint == nil
    }

    /// Why Create Task waits for the user, when a pill has no value.
    var missingChoiceHint: String? {
        if workspaceID == nil { return "Pick a workspace with ⌘1" }
        if preset == nil { return "Pick an agent with ⌘2" }
        return nil
    }

    /// The Workspace pill's value: with a coordinator, "Auto" until the
    /// user chooses.
    var workspacePillTitle: String {
        sendsToCoordinator && choseWorkspace == false ? Self.autoTitle : workspaceTitle
    }

    var agentPillParts: (name: String, effort: String?) {
        sendsToCoordinator && chosePreset == false ? (Self.autoTitle, nil) : agentTitleParts
    }

    var agentPillTitle: String {
        sendsToCoordinator && chosePreset == false ? Self.autoTitle : agentTitle
    }

    static let autoTitle = "Auto"

    /// Sets the Workspace pill. `nil` leaves the project to the
    /// coordinator, and a direct create uses the workspace the panel
    /// started on again.
    func chooseWorkspace(_ id: UUID?) {
        workspaceID = id ?? startingWorkspaceID
        choseWorkspace = id != nil
    }

    /// Sets the Agent pill. `nil` leaves the agent to the coordinator, and
    /// a direct create uses the preset the panel started on again.
    func choosePreset(_ preset: QuickEntryPreset?) {
        self.preset = preset ?? startingPreset
        chosePreset = preset != nil
    }

    /// The pill's workspace closed while the draft was open: it has no
    /// workspace now, chosen or not.
    func workspaceClosed() {
        if startingWorkspaceID == workspaceID { startingWorkspaceID = nil }
        workspaceID = nil
        choseWorkspace = false
    }

    /// The project a later opener names for the message, as its hint.
    func setSelectedProject(_ project: CoordinatorMessageHeader.Workspace?) {
        coordinator?.selectedProject = project
    }

    var canAttachMore: Bool { attachmentDraft.canAttachMore }

    var workspaceTitle: String {
        workspaceID.flatMap { id in workspaceOptions.first { $0.id == id.uuidString }?.title } ?? "None"
    }

    /// `model · effort`, with the model's short name, such as opus-5.5. The
    /// model names its provider, so the profile's name is added only when no
    /// model is chosen. A profile that runs
    /// another provider's command, such as a release profile wrapping
    /// Codex, takes no model, so it always shows its name.
    var agentTitle: String {
        let parts = agentTitleParts
        return parts.effort.map { "\(parts.name) · \($0)" } ?? parts.name
    }

    /// The pill cuts a long model short but keeps the effort.
    var agentTitleParts: (name: String, effort: String?) {
        guard let preset else { return ("None", nil) }
        let name = agentProfiles.first { $0.id == preset.agent }?.displayName ?? preset.agent
        return (preset.model.map(QuickEntryPreset.shortModelName) ?? name, preset.effort)
    }

    func showError(_ message: String) {
        errorMessage = message
    }

    func requestFocus() {
        focusRequestID &+= 1
    }

    /// Adds what a later opener asks for while the panel is already open.
    func apply(_ prefill: QuickEntryPrefill) {
        guard isEditable else { return }
        if let workspaceID = prefill.workspaceID {
            // The opener's workspace is where the panel starts now. It is
            // not the user's choice in this panel.
            self.workspaceID = workspaceID
            startingWorkspaceID = workspaceID
            choseWorkspace = false
        }
        if let selectionText = prefill.selectionText,
           selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            attachText(selectionText, named: "selection.txt")
        }
    }

    func cancel() {
        guard isSubmitting == false else { return }
        onCancel()
    }

    /// Ends the draft when the panel closes. The staging folder goes once no
    /// copy is still writing into it; after a create, `task.create` has
    /// already made its own copies.
    func close() {
        attachmentDraft.close()
    }

    /// For app termination: removes the staging folder at once.
    func removeStagingDirectoryNow() {
        attachmentDraft.removeStagingDirectoryNow()
    }

    func removeAttachment(id: Attachment.ID) {
        attachmentDraft.remove(id: id)
    }

    // MARK: - Submit

    /// ⌘↩: sends to the coordinator, or without one creates the task.
    func submit() {
        guard sendsToCoordinator else {
            createTask()
            return
        }
        sendToCoordinator()
    }

    private func sendToCoordinator() {
        guard canSubmit, let coordinator else { return }
        isSubmitting = true
        errorMessage = nil
        let project = choseWorkspace ? workspaceID.map { id in
            CoordinatorMessageHeader.Workspace(id: id, title: workspaceTitle)
        } : nil
        let chosen = chosePreset ? preset : nil
        let message = CoordinatorUserMessage(
            id: coordinatorMessageID,
            text: text,
            files: attachments.map(\.url),
            quickEntry: CoordinatorMessageHeader.QuickEntry(
                project: project,
                agent: chosen?.agent,
                model: chosen?.model,
                effort: chosen?.effort,
                selectedProject: coordinator.selectedProject
            )
        )
        Task { @MainActor in
            do {
                let result = try await coordinator.send(message)
                isSubmitting = false
                onSent(result)
            } catch {
                isSubmitting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// ⌥⌘↩, and ⌘↩ without a coordinator: creates the task directly, in
    /// the workspace and with the preset of the pills.
    func createTask() {
        guard canCreateTask else {
            // With a coordinator the pills are optional, so the key needs
            // to say what it lacks.
            if sendsToCoordinator, hasDraft, let missingChoiceHint {
                errorMessage = "\(missingChoiceHint) to create the task directly."
            }
            return
        }
        isSubmitting = true
        errorMessage = nil
        let request = TaskCreateRequest(
            text: text,
            files: attachments.map { $0.url.path(percentEncoded: false) },
            clientRequestID: clientRequestID,
            workspaceID: workspaceID,
            agent: preset?.agent,
            model: preset?.model,
            effort: preset?.effort
        )
        Task { @MainActor in
            do {
                let record = try await create(request)
                isSubmitting = false
                onCreated(record)
            } catch {
                isSubmitting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Attachments

    func attachFiles(_ urls: [URL]) {
        attachmentDraft.attachFiles(urls)
    }

    func attachImageData(_ data: Data, named name: String = "Pasted image.png") {
        attachmentDraft.attachImageData(data, named: name)
    }

    func attachText(_ text: String, named name: String) {
        attachmentDraft.attachText(text, named: name)
    }

    @discardableResult
    func pasteAttachments(from pasteboard: NSPasteboard) -> Bool {
        attachmentDraft.pasteAttachments(from: pasteboard)
    }

    /// Files, promised files and images are attached, and a web link is
    /// added to the text.
    func handleDrop(from pasteboard: NSPasteboard) -> Bool {
        attachmentDraft.handleDrop(from: pasteboard)
    }

    func beginPromisedAttachment() -> DraftAttachments.PromisedAttachment? {
        attachmentDraft.beginPromisedAttachment()
    }

    func finishPromisedAttachment(_ result: Result<URL, any Error>) {
        attachmentDraft.finishPromisedAttachment(result)
    }

    private func appendLine(_ line: String) {
        if text.isEmpty || text.hasSuffix("\n") {
            text += line
        } else {
            text += "\n" + line
        }
    }
}
