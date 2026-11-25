import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

/// The New Task form, as the Mac's quick entry: the task text and files, a
/// Workspace pill, Agent, Model and Effort pills (the Mac's Agent picker
/// columns), and the Mac's Frequent presets. The model owns every
/// decision; this view only draws it and forwards edits.
///
/// While the Mac has a coordinator, the form is titled To Coordinator, as
/// the Mac's panel is labeled: the Workspace and Agent pills start as Auto,
/// and the action is Send. Once the user sets both pills, the form has
/// nothing left for the coordinator to choose: it is titled New Task, and
/// the action becomes Create, which makes the task directly.
struct ToasttyNewTaskSheet: View {
    let model: ToasttyNewTaskModel
    /// Called once the Mac saved the task, before the sheet dismisses itself.
    let onCreated: () -> Void
    /// Called once the coordinator has the message or the Mac keeps it,
    /// before the sheet dismisses itself.
    var onSent: (RemoteCoordinatorSendResult) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    /// The agent the Other model prompt opened for, while it shows.
    @State private var customModelProfileID: String?
    @State private var customModelText = ""
    @FocusState private var textIsFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(ToasttyDesignTokens.background)
                .navigationTitle(model.createsDirectly ? "New Task" : "To Coordinator")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Closing while the Mac is saving would lose the
                        // answer, and a later attempt could make a second task.
                        Button("Cancel") {
                            model.discardDraft()
                            dismiss()
                        }
                        .disabled(model.isSubmitting)
                        .accessibilityIdentifier("toastty-mobile-new-task-cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.phase == .creating {
                            ProgressView()
                                .accessibilityLabel("Creating")
                                .accessibilityIdentifier("toastty-mobile-new-task-creating")
                        } else if model.phase == .sending {
                            ProgressView()
                                .accessibilityLabel("Sending")
                                .accessibilityIdentifier("toastty-mobile-new-task-sending")
                        } else if model.createsDirectly == false {
                            Button("Send") {
                                textIsFocused = false
                                Task { await model.send() }
                            }
                            .fontWeight(.semibold)
                            .disabled(model.canSend == false)
                            .accessibilityIdentifier("toastty-mobile-new-task-send")
                        } else {
                            Button("Create") {
                                textIsFocused = false
                                Task { await model.create() }
                            }
                            .fontWeight(.semibold)
                            .disabled(model.canCreate == false)
                            .accessibilityIdentifier("toastty-mobile-new-task-create")
                        }
                    }
                }
        }
        .tint(ToasttyDesignTokens.amber)
        .presentationDragIndicator(.visible)
        // A swipe would discard the draft as Cancel does, so only the
        // buttons close the sheet once there is something to lose.
        .interactiveDismissDisabled(model.preventsInteractiveDismissal)
        .accessibilityIdentifier("toastty-mobile-new-task-sheet")
        .task { await model.loadOptions() }
        .onChange(of: model.phase) { _, phase in
            switch phase {
            case .created:
                onCreated()
                dismiss()
            case .sent(let result):
                onSent(result)
                dismiss()
            case .loading, .unreachable, .form, .creating, .sending:
                break
            }
        }
        .alert("Other model", isPresented: customModelPromptIsPresented) {
            TextField("Model ID", text: $customModelText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Use") {
                if let profileID = customModelProfileID { model.useCustomModel(customModelText, for: profileID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type the model ID that \(customModelAgentName) accepts.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Asking your Mac…")
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .padding(.top, 48)
                .accessibilityIdentifier("toastty-mobile-new-task-loading")
        case .unreachable:
            ContentUnavailableView {
                Label("Couldn't reach your Mac", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Make sure the Mac is awake and Toastty is running, then try again.")
            } actions: {
                Button("Try again") { Task { await model.loadOptions() } }
                    .buttonStyle(ToasttyPrimaryButtonStyle())
            }
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            .accessibilityIdentifier("toastty-mobile-new-task-unreachable")
        case .form, .creating, .created, .sending, .sent:
            form
        }
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let blocking = model.blockingMessage {
                    note(blocking, tone: .warning, identifier: "toastty-mobile-new-task-blocked")
                    // The fix happens on the Mac, so the draft waits here.
                    Button {
                        Task { await model.reloadOptions() }
                    } label: {
                        if model.isReloadingOptions {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Check again")
                        }
                    }
                    .disabled(model.isReloadingOptions)
                    .accessibilityIdentifier("toastty-mobile-new-task-check-again")
                }
                if let error = model.errorMessage {
                    note(error, tone: .error, identifier: "toastty-mobile-new-task-error")
                }
                if let coordinatorNote = model.coordinatorNote {
                    note(
                        coordinatorNote,
                        tone: model.coordinatorNoteIsWarning ? .warning : .info,
                        identifier: "toastty-mobile-new-task-coordinator-note"
                    )
                }
                textEditor
                if ToasttyAttachmentTray.isVisible(
                    attachments: model.attachments,
                    supportsAttachments: model.supportsAttachments,
                    allowsInput: model.allowsAttachmentInput,
                    isLoading: model.isLoadingAttachments
                ) {
                    ToasttyAttachmentTray(
                        attachments: model.attachments,
                        supportsAttachments: model.supportsAttachments,
                        allowsInput: model.allowsAttachmentInput,
                        isLoading: model.isLoadingAttachments,
                        removeAttachment: model.removeAttachment
                    )
                }
                // A pill that does not fit moves to the next line before
                // any pill truncates. Model and Effort show only for an
                // agent that takes them.
                ToasttyChipFlowLayout(spacing: 8, lineSpacing: 8) {
                    workspacePill
                    agentPill
                    if model.showsModelAndEffort, let agent = model.selectedAgent {
                        if agent.supportsModel {
                            modelPill
                        }
                        if agent.reasoningEfforts.isEmpty == false {
                            effortPill(agent)
                        }
                    }
                }
                .disabled(model.allowsEditing == false)
                if model.frequentPresets.isEmpty == false {
                    frequent
                }
                if let line = createLine {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                        .padding(.top, 4)
                        .accessibilityIdentifier("toastty-mobile-new-task-footer")
                }
            }
            .padding(16)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var textEditor: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("What should the agent do?")
                        .font(.body)
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .accessibilityHidden(true)
                }
                TextEditor(text: textBinding)
                    .font(.body)
                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                    .scrollContentBackground(.hidden)
                    .focused($textIsFocused)
                    .frame(minHeight: 140)
                    .disabled(model.allowsEditing == false)
                    .accessibilityLabel("Task")
                    .accessibilityHint("What should the agent do?")
                    .accessibilityIdentifier("toastty-mobile-new-task-text")
            }
            ToasttyAttachmentPicker(
                attachments: model.attachments,
                supportsAttachments: model.supportsAttachments,
                allowsInput: model.allowsAttachmentInput,
                isLoading: attachmentLoadingBinding,
                addAttachments: model.addAttachments
            )
        }
        .padding(8)
        .background(ToasttyDesignTokens.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous)
                .stroke(textIsFocused ? ToasttyDesignTokens.amber.opacity(0.6) : ToasttyDesignTokens.border, lineWidth: 1)
        }
    }

    private var workspacePill: some View {
        Menu {
            Picker("Workspace", selection: workspaceSelection) {
                // The first row leaves the choice to the coordinator, as
                // in the Mac's list.
                if model.sendsToCoordinator {
                    Text(ToasttyNewTaskModel.autoTitle).tag(UUID?.none)
                }
                ForEach(model.workspaces) { workspace in
                    Text(workspace.title).tag(Optional(workspace.id))
                }
            }
        } label: {
            pill(label: "Workspace", value: model.workspacePillTitle, isAuto: model.workspaceIsAuto)
        }
        .accessibilityLabel("Workspace")
        .accessibilityValue(model.workspacePillTitle)
        .accessibilityIdentifier("toastty-mobile-new-task-workspace")
    }

    /// Agent, Model and Effort are one pill each, as the Mac's Agent picker
    /// has a column for each. A Frequent chip sets all three.
    private var agentPill: some View {
        Menu {
            Picker("Agent", selection: agentSelection) {
                if model.sendsToCoordinator {
                    Text(ToasttyNewTaskModel.autoTitle).tag(String?.none)
                }
                ForEach(model.agents) { agent in
                    Text(agent.displayName).tag(Optional(agent.profileID))
                }
            }
        } label: {
            pill(label: "Agent", value: model.agentPillTitle, isAuto: model.agentIsAuto)
        }
        .accessibilityLabel("Agent")
        .accessibilityValue(model.agentPillTitle)
        .accessibilityIdentifier("toastty-mobile-new-task-agent")
    }

    private var modelPill: some View {
        Menu {
            Picker("Model", selection: modelSelection) {
                Text(ToasttyNewTaskModel.defaultChoiceTitle).tag(String?.none)
                ForEach(model.modelChoices, id: \.self) { value in
                    Text(ToasttyNewTaskModel.shortModelName(value)).tag(Optional(value))
                }
            }
            Divider()
            Button("Other…") {
                customModelText = model.preset?.model ?? ""
                customModelProfileID = model.preset?.profileID
            }
        } label: {
            pill(label: "Model", value: model.modelTitle)
        }
        .accessibilityLabel("Model")
        .accessibilityValue(model.modelTitle)
        .accessibilityIdentifier("toastty-mobile-new-task-model")
    }

    private func effortPill(_ agent: RemoteSessionStartAgent) -> some View {
        Menu {
            Picker("Effort", selection: effortSelection) {
                Text(ToasttyNewTaskModel.defaultChoiceTitle).tag(String?.none)
                ForEach(agent.reasoningEfforts, id: \.self) { value in
                    Text(value).tag(Optional(value))
                }
            }
        } label: {
            pill(label: "Effort", value: model.effortTitle)
        }
        .accessibilityLabel("Effort")
        .accessibilityValue(model.effortTitle)
        .accessibilityIdentifier("toastty-mobile-new-task-effort")
    }

    private var frequent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FREQUENT")
                .font(.caption2.monospaced())
                .tracking(0.8)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
            ToasttyChipFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Array(model.frequentPresets.enumerated()), id: \.element) { index, preset in
                    frequentChip(preset, index: index)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Frequent")
        .accessibilityIdentifier("toastty-mobile-new-task-frequent")
    }

    private func frequentChip(_ preset: RemoteTaskPreset, index: Int) -> some View {
        // On Auto no preset is the user's choice.
        let isSelected = preset == model.preset && model.agentIsAuto == false
        return Button {
            model.selectPreset(preset)
        } label: {
            Text(ToasttyNewTaskModel.title(preset))
                .font(.caption.monospaced())
                .foregroundStyle(isSelected ? ToasttyDesignTokens.inkOnAmber : ToasttyDesignTokens.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(isSelected ? ToasttyDesignTokens.amber : ToasttyDesignTokens.chipSurface, in: Capsule())
                .overlay {
                    Capsule().stroke(isSelected ? Color.clear : ToasttyDesignTokens.border, lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.allowsEditing == false)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("toastty-mobile-new-task-frequent-\(index)")
    }

    /// The line under the pills. Without a coordinator it says what Create
    /// does. With one, it shows only once the user set both pills, to say
    /// why Send became Create. Under Auto the form needs no line.
    private var createLine: String? {
        guard model.sendsToCoordinator else { return "The Mac saves the task at once and runs setup." }
        guard model.createsDirectly, let preset = model.preset else { return nil }
        return "Create makes the task now in \(model.workspaceTitle) with \(ToasttyNewTaskModel.title(preset)), without the coordinator."
    }

    // MARK: - Pieces

    private func pill(label: String, value: String, isAuto: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.monospaced())
                .tracking(0.6)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .lineLimit(1)
                .fixedSize()
            // "Auto": the coordinator chooses. Quieter than a value, as on
            // the Mac.
            Text(value)
                .font(.subheadline)
                .foregroundStyle(isAuto ? ToasttyDesignTokens.secondaryText : ToasttyDesignTokens.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .imageScale(.small)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(ToasttyDesignTokens.raisedSurface, in: Capsule())
        .overlay {
            Capsule().stroke(ToasttyDesignTokens.border, lineWidth: 1)
        }
        .contentShape(Capsule())
    }

    private enum NoteTone {
        case info
        case warning
        case error
    }

    private func note(_ text: String, tone: NoteTone, identifier: String) -> some View {
        let color = switch tone {
        case .info: ToasttyDesignTokens.secondaryText
        case .warning: ToasttyDesignTokens.amberText
        case .error: ToasttyDesignTokens.red
        }
        let symbol = switch tone {
        case .info: "clock"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.octagon"
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous)
                .stroke(color.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var customModelPromptIsPresented: Binding<Bool> {
        Binding(get: { customModelProfileID != nil }, set: { if $0 == false { customModelProfileID = nil } })
    }

    private var customModelAgentName: String {
        model.agents.first { $0.profileID == customModelProfileID }?.displayName ?? "the agent"
    }

    /// `nil` is Auto while the sheet sends to the coordinator.
    private var agentSelection: Binding<String?> {
        Binding(get: { model.agentIsAuto ? nil : model.preset?.profileID }, set: { id in
            if let agent = model.agents.first(where: { $0.profileID == id }) {
                model.selectAgent(agent)
            } else if id == nil {
                model.selectAutoAgent()
            }
        })
    }

    private var modelSelection: Binding<String?> {
        Binding(get: { model.preset?.model }, set: { value in model.selectModel(value) })
    }

    private var effortSelection: Binding<String?> {
        Binding(get: { model.preset?.effort }, set: { value in model.selectEffort(value) })
    }

    /// `nil` is Auto while the sheet sends to the coordinator.
    private var workspaceSelection: Binding<UUID?> {
        Binding(get: { model.workspaceIsAuto ? nil : model.workspaceID }, set: { id in
            if let id {
                model.selectWorkspace(id)
            } else {
                model.selectAutoWorkspace()
            }
        })
    }

    private var textBinding: Binding<String> {
        Binding(get: { model.text }, set: { model.updateText($0) })
    }

    private var attachmentLoadingBinding: Binding<Bool> {
        Binding(get: { model.isLoadingAttachments }, set: { model.setIsLoadingAttachments($0) })
    }
}

/// Presents the New Task sheet for `model`, and says the task was saved,
/// or where the coordinator's message went, once the sheet has closed.
private struct ToasttyNewTaskSheetModifier: ViewModifier {
    @Binding var model: ToasttyNewTaskModel?
    let controller: HomeScreenController
    @State private var created = false
    @State private var sent: RemoteCoordinatorSendResult?

    func body(content: Content) -> some View {
        content.sheet(item: $model, onDismiss: didDismiss) { model in
            ToasttyNewTaskSheet(model: model, onCreated: { created = true }, onSent: { sent = $0 })
                // Content shared from another app waits for this sheet too.
                .onAppear { controller.isShowingNewSessionForm = true }
        }
    }

    private func didDismiss() {
        controller.isShowingNewSessionForm = false
        if let sent {
            self.sent = nil
            controller.announceCoordinatorSend(sent)
        } else if created {
            created = false
            controller.announceTaskCreated()
        }
    }
}

extension View {
    func toasttyNewTaskSheet(
        _ model: Binding<ToasttyNewTaskModel?>,
        controller: HomeScreenController
    ) -> some View {
        modifier(ToasttyNewTaskSheetModifier(model: model, controller: controller))
    }
}
