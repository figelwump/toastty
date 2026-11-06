import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

/// The New Task form, as the Mac's quick entry: the task text and files, a
/// Workspace pill, an Agent pill, and the Mac's Frequent presets. The model
/// owns every decision; this view only draws it and forwards edits.
struct ToasttyNewTaskSheet: View {
    let model: ToasttyNewTaskModel
    /// Called once the Mac saved the task, before the sheet dismisses itself.
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var customModelAgent: RemoteSessionStartAgent?
    @State private var customModelText = ""
    @FocusState private var textIsFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(ToasttyDesignTokens.background)
                .navigationTitle("New Task")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Closing while the Mac is saving would lose the
                        // answer, and a later attempt could make a second task.
                        Button("Cancel") {
                            model.discardDraft()
                            dismiss()
                        }
                        .disabled(model.phase == .creating)
                        .accessibilityIdentifier("toastty-mobile-new-task-cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.phase == .creating {
                            ProgressView()
                                .accessibilityLabel("Creating")
                                .accessibilityIdentifier("toastty-mobile-new-task-creating")
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
            guard phase == .created else { return }
            onCreated()
            dismiss()
        }
        .alert("Other model", isPresented: customModelPromptIsPresented) {
            TextField("Model ID", text: $customModelText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Use") {
                if let agent = customModelAgent { model.useCustomModel(customModelText, for: agent) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type the model ID that \(customModelAgent?.displayName ?? "the agent") accepts.")
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
        case .form, .creating, .created:
            form
        }
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let blocking = model.blockingMessage {
                    note(blocking, tone: .warning, identifier: "toastty-mobile-new-task-blocked")
                }
                if let error = model.errorMessage {
                    note(error, tone: .error, identifier: "toastty-mobile-new-task-error")
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
                HStack(spacing: 8) {
                    workspacePill
                    agentPill
                }
                .disabled(model.allowsEditing == false)
                if model.frequentPresets.isEmpty == false {
                    frequent
                }
                Text("The Mac saves the task at once and runs setup.")
                    .font(.footnote)
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .padding(.top, 4)
                    .accessibilityIdentifier("toastty-mobile-new-task-footer")
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
                ForEach(model.workspaces) { workspace in
                    Text(workspace.title).tag(Optional(workspace.id))
                }
            }
        } label: {
            pill(label: "Workspace", value: model.workspaceTitle)
        }
        .accessibilityLabel("Workspace")
        .accessibilityValue(model.workspaceTitle)
        .accessibilityIdentifier("toastty-mobile-new-task-workspace")
    }

    /// Each agent opens its own menu of models and efforts, as the Mac's
    /// Agent picker lists them.
    private var agentPill: some View {
        Menu {
            ForEach(model.agents) { agent in
                Menu(agent.displayName) {
                    if agent.supportsModel {
                        Section("Model") {
                            choice("Profile default", isSelected: isSelected(agent) && model.preset?.model == nil) {
                                model.selectModel(nil, for: agent)
                            }
                            ForEach(model.modelChoices(for: agent), id: \.self) { value in
                                choice(ToasttyNewTaskModel.shortModelName(value), isSelected: isSelected(agent) && model.preset?.model == value) {
                                    model.selectModel(value, for: agent)
                                }
                            }
                            Button("Other…") {
                                customModelText = isSelected(agent) ? model.preset?.model ?? "" : ""
                                customModelAgent = agent
                            }
                        }
                    }
                    if agent.reasoningEfforts.isEmpty == false {
                        Section("Effort") {
                            choice("Profile default", isSelected: isSelected(agent) && model.preset?.effort == nil) {
                                model.selectEffort(nil, for: agent)
                            }
                            ForEach(agent.reasoningEfforts, id: \.self) { value in
                                choice(value, isSelected: isSelected(agent) && model.preset?.effort == value) {
                                    model.selectEffort(value, for: agent)
                                }
                            }
                        }
                    }
                    if agent.supportsModel == false, agent.reasoningEfforts.isEmpty {
                        choice("Use \(agent.displayName)", isSelected: isSelected(agent)) {
                            model.selectPreset(RemoteTaskPreset(profileID: agent.profileID))
                        }
                    }
                }
            }
        } label: {
            pill(label: "Agent", value: model.agentTitle)
        }
        .accessibilityLabel("Agent")
        .accessibilityValue(model.agentTitle)
        .accessibilityIdentifier("toastty-mobile-new-task-agent")
    }

    private var frequent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FREQUENT")
                .font(.caption2.monospaced())
                .tracking(0.8)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(model.frequentPresets.enumerated()), id: \.element) { index, preset in
                        frequentChip(preset, index: index)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Frequent")
        .accessibilityIdentifier("toastty-mobile-new-task-frequent")
    }

    private func frequentChip(_ preset: RemoteTaskPreset, index: Int) -> some View {
        let isSelected = preset == model.preset
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

    // MARK: - Pieces

    private func isSelected(_ agent: RemoteSessionStartAgent) -> Bool {
        model.preset?.profileID == agent.profileID
    }

    private func choice(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func pill(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.monospaced())
                .tracking(0.6)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
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
        case warning
        case error
    }

    private func note(_ text: String, tone: NoteTone, identifier: String) -> some View {
        let color = tone == .error ? ToasttyDesignTokens.red : ToasttyDesignTokens.amberText
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone == .error ? "exclamationmark.octagon" : "exclamationmark.triangle")
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
        Binding(get: { customModelAgent != nil }, set: { if $0 == false { customModelAgent = nil } })
    }

    private var workspaceSelection: Binding<UUID?> {
        Binding(get: { model.workspaceID }, set: { id in id.map(model.selectWorkspace) })
    }

    private var textBinding: Binding<String> {
        Binding(get: { model.text }, set: { model.updateText($0) })
    }

    private var attachmentLoadingBinding: Binding<Bool> {
        Binding(get: { model.isLoadingAttachments }, set: { model.setIsLoadingAttachments($0) })
    }
}

/// Presents the New Task sheet for `model`, and says the task was saved
/// once the sheet has closed.
private struct ToasttyNewTaskSheetModifier: ViewModifier {
    @Binding var model: ToasttyNewTaskModel?
    let controller: HomeScreenController
    @State private var created = false

    func body(content: Content) -> some View {
        content.sheet(item: $model, onDismiss: didDismiss) { model in
            ToasttyNewTaskSheet(model: model) { created = true }
                // Content shared from another app waits for this sheet too.
                .onAppear { controller.isShowingNewSessionForm = true }
        }
    }

    private func didDismiss() {
        controller.isShowingNewSessionForm = false
        guard created else { return }
        created = false
        controller.announceTaskCreated()
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
