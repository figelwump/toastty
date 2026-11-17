import RemoteProtocol
import SwiftUI

/// A Claude permission request: what it would do, and one button per decision.
/// The decision is the interaction's single question; a tap selects that one
/// option and sends it, the same way a question answer is sent.
struct ToasttyPermissionRequestContent: View {
    let interaction: RemotePendingInteraction
    let permission: RemotePermissionRequestDetail
    let decision: RemoteInteractionQuestion
    /// Present only while this phone can still answer.
    let answerState: ToasttyInteractionAnswerState?
    let sentOptionID: String?
    let readOnlyMessage: String
    let onChoose: (String) -> Void

    private static let previewMaximumHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(interaction.prompt)
                .font(.body)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let description = permission.description, description.isEmpty == false,
               description != interaction.prompt {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            preview

            if let answerState {
                actions(answerState)
            } else {
                outcome
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if permission.preview.isEmpty == false {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView {
                    Text(permission.preview)
                        .font(.caption.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: Self.previewMaximumHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(ToasttyDesignTokens.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityIdentifier("toastty-mobile-permission-preview-\(interaction.id.rawValue)")
                if permission.previewTruncated {
                    Label("Preview shortened. Check the desktop for the full request.", systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(ToasttyDesignTokens.amberText)
                }
            }
        }
    }

    private func actions(_ state: ToasttyInteractionAnswerState) -> some View {
        let enabled = state.connectionIsLive && Self.isChoosable(state.status)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(decision.options, id: \.id) { option in
                decisionButton(option, state: state, enabled: enabled)
            }
            statusView(state)
            Label("You can also respond on the desktop", systemImage: "desktopcomputer")
                .font(.caption)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
        }
    }

    private func decisionButton(
        _ option: RemotePendingInteraction.Option,
        state: ToasttyInteractionAnswerState,
        enabled: Bool
    ) -> some View {
        let kind = ClaudeDecisionKind(optionID: option.id)
        let isSending = state.status == .submitting && sentOptionID == option.id
        return Button {
            onChoose(option.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: kind == .allowOnce ? .center : .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(kind == .allowOnce ? .center : .leading)
                    if let detail = option.detail, detail.isEmpty == false, kind != .allowOnce {
                        Text(detail)
                            .font(.caption)
                            .opacity(0.8)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: kind == .allowOnce ? .center : .leading)
                if isSending { ProgressView().controlSize(.small) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .modifier(DecisionButtonStyle(kind: kind))
        .disabled(enabled == false)
        .accessibilityIdentifier("toastty-mobile-permission-option-\(interaction.id.rawValue)-\(option.id)")
    }

    @ViewBuilder
    private func statusView(_ state: ToasttyInteractionAnswerState) -> some View {
        switch state.status {
        case .editing where state.connectionIsLive == false:
            Label("Reconnect to your Mac to respond", systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
        case .submitting:
            Text("Sending…")
                .font(.caption)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
        case .awaitingClaude:
            Label("Sent · \(sentLabel ?? "decision") · waiting for Claude", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(ToasttyDesignTokens.amberText)
        case .failed(let message), .unavailable(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(ToasttyDesignTokens.amberText)
                .fixedSize(horizontal: false, vertical: true)
        case .editing, .resolved:
            EmptyView()
        }
    }

    /// No provider fact says which answer Claude took when the desktop
    /// answered at the same moment, so the phone reports only what it sent.
    @ViewBuilder
    private var outcome: some View {
        if let sentLabel {
            Label("Sent from iPhone: \(sentLabel)", systemImage: "iphone")
                .font(.caption.weight(.semibold))
                .foregroundStyle(interaction.state == .pending
                    ? ToasttyDesignTokens.amberText : ToasttyDesignTokens.secondaryText)
        } else if interaction.state == .pending {
            Label(readOnlyMessage, systemImage: "desktopcomputer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.amberText)
        }
    }

    private var sentLabel: String? {
        guard let sentOptionID else { return nil }
        return decision.options.first { $0.id == sentOptionID }?.label
    }

    private static func isChoosable(_ status: ToasttyInteractionAnswerStatus) -> Bool {
        switch status {
        case .editing, .failed: true
        case .submitting, .awaitingClaude, .unavailable, .resolved: false
        }
    }
}

private enum ClaudeDecisionKind {
    case allowOnce, alwaysAllow, deny

    init(optionID: String) {
        switch ClaudePermissionOptionID(rawValue: optionID) {
        case .allow: self = .allowOnce
        case .deny: self = .deny
        case nil: self = .alwaysAllow
        }
    }
}

/// Option IDs the Mac assigns to a Claude permission decision. Any other
/// option is one of Claude's "always allow" suggestions.
private enum ClaudePermissionOptionID: String {
    case allow
    case deny
}

private struct DecisionButtonStyle: ViewModifier {
    let kind: ClaudeDecisionKind

    func body(content: Content) -> some View {
        switch kind {
        case .allowOnce:
            content
                .buttonStyle(.borderedProminent)
                .tint(ToasttyDesignTokens.amber)
                .foregroundStyle(ToasttyDesignTokens.inkOnAmber)
        case .alwaysAllow:
            content
                .buttonStyle(.bordered)
                .tint(ToasttyDesignTokens.amberText)
        case .deny:
            content
                .buttonStyle(.bordered)
                .tint(ToasttyDesignTokens.red)
        }
    }
}
