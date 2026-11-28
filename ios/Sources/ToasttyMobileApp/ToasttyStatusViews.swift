import ConversationUI
import SwiftUI
import ToasttyMobileDomain

struct ToasttyConnectionPill: View {
    let state: MobileConnectionState
    let hostName: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
            Text(state.rawValue)
            Text("·")
            Text(hostName)
        }
        .font(.caption2.monospaced())
        .foregroundStyle(ToasttyDesignTokens.mutedText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection \(state.rawValue) to \(hostName)")
        .accessibilityIdentifier("toastty-mobile-connection")
    }

    private var stateColor: Color {
        switch state {
        case .live: ToasttyDesignTokens.green
        case .reconnecting: ToasttyDesignTokens.amber
        case .offline: ToasttyDesignTokens.offline
        }
    }
}

/// Why the lists may be out of date while the connection is not live, with
/// Retry while Toastty reconnects. Home and the Tasks tab show it above
/// their lists; it draws nothing while the connection is live.
struct ToasttyConnectionNotice: View {
    let controller: HomeScreenController
    let refresh: () async -> Void

    @State private var isRetryingConnection = false

    var body: some View {
        if let message = controller.connectionNoticeMessage {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 9) {
                    indicator
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(controller.freshness.accessibilityLabel). \(message)")
                .accessibilityValue(showsProgressIndicator ? "In progress" : "")
                .accessibilityIdentifier("toastty-mobile-connection-notice")

                if controller.freshness == .reconnecting {
                    Button("Retry", action: retryConnection)
                        .buttonStyle(.bordered)
                        .frame(minWidth: 44, minHeight: 44)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .disabled(isRetryingConnection)
                        .accessibilityLabel("Retry connection")
                        .accessibilityIdentifier("toastty-mobile-connection-retry")
                }
            }
            .font(.caption)
            .foregroundStyle(controller.freshness == .unreachable
                ? ToasttyDesignTokens.red
                : ToasttyDesignTokens.amberText)
            .toasttyCard()
        }
    }

    private func retryConnection() {
        guard isRetryingConnection == false else { return }
        isRetryingConnection = true
        Task { @MainActor in
            await refresh()
            isRetryingConnection = false
        }
    }

    @ViewBuilder
    private var indicator: some View {
        if showsProgressIndicator {
            ProgressView()
                .controlSize(.small)
                .tint(ToasttyDesignTokens.amber)
        } else {
            Image(systemName: controller.freshness == .unreachable
                ? "wifi.slash"
                : "arrow.trianglehead.2.clockwise.rotate.90")
        }
    }

    private var showsProgressIndicator: Bool {
        controller.freshness == .reconnecting || controller.freshness == .connecting
    }
}

struct ToasttySessionStatusPresentation: Equatable, Sendable {
    let bucket: MobileSessionBucket
    let freshness: LiveProjectionFreshness

    var isVisible: Bool { bucket.isVisible }
    var showsWorkingSpinner: Bool { freshness == .live && bucket == .working }
    var label: String {
        freshness == .live ? bucket.rawValue : "last seen \(bucket.rawValue)"
    }
    var accessibilityLabel: String {
        freshness == .live ? bucket.rawValue : "Last seen \(bucket.rawValue). Updates paused."
    }

    func accessibilitySummary(for conversation: MobileConversation) -> String {
        let facts: [String?] = [
            ToasttySessionRowPresentation.title(for: conversation),
            isVisible ? accessibilityLabel : conversation.state.accessibilityLabel,
            conversation.waiting.map { "waiting on \($0.summary.rowText(.full))" },
            conversation.lastActivity,
            conversation.workspaceTitle,
            conversation.agent.displayName,
            conversation.cwd,
            conversation.displayAge,
            conversation.isFlaggedForLater ? "flagged for later" : nil,
        ]
        return facts
            .compactMap(Self.nonemptyTrimmed)
            .joined(separator: ", ")
    }

    private static func nonemptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Session status remains a last-known host fact while the projection is
/// stale. Only a live projection can animate working activity; disconnected
/// views use a neutral, static treatment without rewriting the cached state.
struct ToasttySessionStatusLabel: View {
    let bucket: MobileSessionBucket
    let freshness: LiveProjectionFreshness

    private var presentation: ToasttySessionStatusPresentation {
        ToasttySessionStatusPresentation(bucket: bucket, freshness: freshness)
    }

    @ViewBuilder
    var body: some View {
        if presentation.isVisible {
            HStack(spacing: 5) {
                if presentation.showsWorkingSpinner {
                    ToasttySpinner(color: statusColor)
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                }
                Text(presentation.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2.monospaced())
            .foregroundStyle(statusColor)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
        }
    }

    private var statusColor: Color {
        freshness == .live
            ? ToasttyDesignTokens.color(for: bucket)
            : ToasttyDesignTokens.mutedText
    }
}

/// A chat header's status: the session's status while the chat is live,
/// "reconnecting…" in its place while the chat reconnects, and the last
/// status the Mac reported once the chat is offline. It changes in place,
/// so the chat never moves for the connection.
struct ToasttyChatConnectionStatusLabel: View {
    let bucket: MobileSessionBucket
    let connection: ToasttyChatConnection

    var body: some View {
        switch connection {
        case .live:
            ToasttySessionStatusLabel(bucket: bucket, freshness: .live)
        case .reconnecting:
            HStack(spacing: 5) {
                ToasttySpinner(color: ToasttyDesignTokens.mutedText)
                Text("reconnecting…")
            }
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.mutedText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reconnecting to your Mac")
        case .offline:
            ToasttySessionStatusLabel(bucket: bucket, freshness: .stale)
        }
    }
}

/// Floats over a chat that has been offline for a while, with Retry.
struct ToasttyChatOfflineNotice: View {
    let retry: () async -> Void

    @State private var isRetrying = false

    var body: some View {
        HStack(spacing: 8) {
            Label("Can\u{2019}t reach your Mac", systemImage: "wifi.slash")
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .accessibilityIdentifier("toastty-mobile-chat-offline-notice")
            Button("Retry") {
                guard isRetrying == false else { return }
                isRetrying = true
                Task { @MainActor in
                    await retry()
                    isRetrying = false
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(ToasttyDesignTokens.amberText)
            .frame(minHeight: 44)
            .disabled(isRetrying)
            .accessibilityLabel("Retry connection")
            .accessibilityIdentifier("toastty-mobile-chat-offline-retry")
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .background(ToasttyDesignTokens.elevatedSurface.opacity(0.97), in: Capsule())
        .overlay { Capsule().strokeBorder(ToasttyDesignTokens.border, lineWidth: 1) }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

struct ToasttySectionTitle: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.monospaced())
            .tracking(1.8)
            .foregroundStyle(ToasttyDesignTokens.mutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
    }
}
