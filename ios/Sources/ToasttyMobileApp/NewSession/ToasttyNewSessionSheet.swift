import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

/// The "New session" form: the workspace, an agent, an optional model and
/// effort, and the first message. The model owns every decision; this view
/// only draws it and forwards edits.
struct ToasttyNewSessionSheet: View {
    let model: ToasttyNewSessionModel
    /// Called once the sheet is done, before it dismisses itself.
    let onFinish: (ToasttyNewSessionModel.Finish) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showsCustomModelPrompt = false
    @State private var customModelText = ""
    @FocusState private var messageIsFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(ToasttyDesignTokens.background)
                .navigationTitle(model.sheetTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Closing while the Mac is starting the session
                        // would lose the answer, and a later attempt could
                        // start a second one.
                        Button("Cancel") { dismiss() }
                            .disabled(model.phase == .starting)
                            .accessibilityIdentifier("toastty-mobile-new-session-cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Start") {
                            messageIsFocused = false
                            Task { await model.start() }
                        }
                        .fontWeight(.semibold)
                        .disabled(model.canStart == false)
                        .accessibilityIdentifier("toastty-mobile-new-session-start")
                    }
                }
        }
        .tint(ToasttyDesignTokens.amber)
        .presentationDragIndicator(.visible)
        // A swipe would discard the typed message as Cancel does, so only
        // the buttons close the sheet once there is something to lose.
        .interactiveDismissDisabled(model.message.isEmpty == false || model.phase == .starting)
        .accessibilityIdentifier("toastty-mobile-new-session-sheet")
        .task { await model.loadOptions() }
        .onChange(of: model.phase) { _, phase in
            guard case .finished(let finish) = phase else { return }
            onFinish(finish)
            dismiss()
        }
        .alert("Other model", isPresented: $showsCustomModelPrompt) {
            TextField("Model ID", text: $customModelText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Use") { model.useCustomModel(customModelText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type the model ID that \(model.selectedAgent?.displayName ?? "the agent") accepts.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Asking your Mac…")
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .padding(.top, 48)
                .accessibilityIdentifier("toastty-mobile-new-session-loading")
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
            .accessibilityIdentifier("toastty-mobile-new-session-unreachable")
        case .form:
            form
        case .starting, .finished:
            starting
        }
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let blocking = model.blockingMessage {
                    note(blocking, tone: .warning, identifier: "toastty-mobile-new-session-blocked")
                }
                if let error = model.errorMessage {
                    note(error, tone: .error, identifier: "toastty-mobile-new-session-error")
                }
                workspaceField
                agentPicker
                ForEach(model.unavailableAgentNotes, id: \.self) { reason in
                    note(reason, tone: .warning, identifier: "toastty-mobile-new-session-agent-note")
                }
                if model.showsModel || model.showsEffort {
                    HStack(alignment: .top, spacing: 10) {
                        if model.showsModel { modelField }
                        if model.showsEffort { effortField }
                    }
                }
                messageEditor
            }
            .padding(16)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var workspaceField: some View {
        field(label: "Workspace") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.workspaceTitle)
                    .font(.subheadline)
                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                Spacer(minLength: 8)
                if let directory = model.options?.launchDirectory {
                    Text(directory)
                        .font(.caption.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toastty-mobile-new-session-workspace")
    }

    private var agentPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(model.agents) { agent in
                    agentSegment(agent)
                }
            }
            .padding(3)
        }
        .scrollIndicators(.hidden)
        .background(ToasttyDesignTokens.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous)
                .stroke(ToasttyDesignTokens.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent")
        .accessibilityIdentifier("toastty-mobile-new-session-agents")
    }

    private func agentSegment(_ agent: RemoteSessionStartAgent) -> some View {
        let isSelected = agent.profileID == model.selectedAgentID
        let isAvailable = agent.availability == .available
        return Button {
            model.selectAgent(agent.profileID)
        } label: {
            Text(agent.displayName)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .strikethrough(isAvailable == false)
                .foregroundStyle(
                    isSelected
                        ? ToasttyDesignTokens.inkOnAmber
                        : (isAvailable ? ToasttyDesignTokens.primaryText : ToasttyDesignTokens.mutedText)
                )
                .padding(.horizontal, 14)
                .frame(minWidth: 72, minHeight: 36)
                .background(
                    isSelected ? ToasttyDesignTokens.amber : Color.clear,
                    in: RoundedRectangle(cornerRadius: ToasttyDesignTokens.chipCornerRadius + 2, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // An unavailable agent stays tappable: the tap shows its reason.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isAvailable ? "" : "Unavailable")
        .accessibilityHint(ToasttyNewSessionModel.unavailableReason(agent) ?? "")
        .accessibilityIdentifier("toastty-mobile-new-session-agent-\(agent.profileID)")
    }

    private var modelField: some View {
        Menu {
            Picker("Model", selection: modelSelection) {
                Text("Profile default").tag(String?.none)
                if model.modelChoices.isEmpty == false {
                    Section("Recent") {
                        ForEach(model.modelChoices, id: \.self) { choice in
                            Text(choice).tag(String?.some(choice))
                        }
                    }
                }
            }
            Divider()
            Button("Other…") {
                customModelText = model.model ?? ""
                showsCustomModelPrompt = true
            }
            .accessibilityIdentifier("toastty-mobile-new-session-model-other")
        } label: {
            menuField(label: "Model", value: model.model ?? "Profile default")
        }
        .accessibilityLabel("Model")
        .accessibilityValue(model.model ?? "Profile default")
        .accessibilityIdentifier("toastty-mobile-new-session-model")
    }

    private var effortField: some View {
        Menu {
            Picker("Effort", selection: effortSelection) {
                Text("Profile default").tag(String?.none)
                ForEach(model.effortChoices, id: \.self) { choice in
                    Text(choice).tag(String?.some(choice))
                }
            }
        } label: {
            menuField(label: "Effort", value: model.effort ?? "Profile default")
        }
        .accessibilityLabel("Effort")
        .accessibilityValue(model.effort ?? "Profile default")
        .accessibilityIdentifier("toastty-mobile-new-session-effort")
    }

    private var messageEditor: some View {
        ZStack(alignment: .topLeading) {
            if model.message.isEmpty {
                Text(model.messagePlaceholder)
                    .font(.body)
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .accessibilityHidden(true)
            }
            TextEditor(text: messageBinding)
                .font(.body)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .scrollContentBackground(.hidden)
                .focused($messageIsFocused)
                .frame(minHeight: 140)
                .accessibilityLabel("First message")
                .accessibilityIdentifier("toastty-mobile-new-session-message")
        }
        .padding(8)
        .background(ToasttyDesignTokens.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous)
                .stroke(messageIsFocused ? ToasttyDesignTokens.amber.opacity(0.6) : ToasttyDesignTokens.border, lineWidth: 1)
        }
    }

    // MARK: - Starting

    private var starting: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        ToasttyPulsingDot()
                        Text("Starting on Mac…")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.amberText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(ToasttyDesignTokens.amber.opacity(0.14), in: Capsule())
                    if let agent = model.selectedAgent {
                        Text(agent.displayName.lowercased())
                            .font(.caption.monospaced())
                            .foregroundStyle(ToasttyDesignTokens.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(ToasttyDesignTokens.chipSurface, in: Capsule())
                    }
                }
                Text(model.message.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.body)
                    .foregroundStyle(ToasttyDesignTokens.userBubbleText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(ToasttyDesignTokens.userBubbleSurface, in: ToasttyDesignTokens.userBubbleShape)
                    .overlay {
                        ToasttyDesignTokens.userBubbleShape.stroke(ToasttyDesignTokens.userBubbleBorder, lineWidth: 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, 40)
                HStack(spacing: 8) {
                    ToasttyPulsingDot()
                    Text("Waiting for \(model.startingAgentName ?? "the agent") to start")
                }
                .font(.footnote)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .accessibilityElement(children: .combine)
            }
            .padding(16)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("toastty-mobile-new-session-starting")
    }

    // MARK: - Pieces

    private enum NoteTone {
        case warning
        case error
    }

    private func note(_ text: String, tone: NoteTone, identifier: String?) -> some View {
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
        .accessibilityIdentifier(identifier ?? "")
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.monospaced())
                .tracking(0.8)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToasttyDesignTokens.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous)
                .stroke(ToasttyDesignTokens.border, lineWidth: 1)
        }
    }

    private func menuField(label: String, value: String) -> some View {
        field(label: label) {
            HStack(spacing: 6) {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
            }
        }
        .contentShape(Rectangle())
    }

    private var modelSelection: Binding<String?> {
        Binding(get: { model.model }, set: { model.selectModel($0) })
    }

    private var effortSelection: Binding<String?> {
        Binding(get: { model.effort }, set: { model.selectEffort($0) })
    }

    private var messageBinding: Binding<String> {
        Binding(get: { model.message }, set: { model.updateMessage($0) })
    }
}

/// The amber dot that marks a session on its way.
private struct ToasttyPulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        Circle()
            .fill(ToasttyDesignTokens.amber)
            .frame(width: 7, height: 7)
            .opacity(isDimmed ? 0.35 : 1)
            .accessibilityHidden(true)
            .onAppear {
                guard reduceMotion == false else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isDimmed = true
                }
            }
    }
}
