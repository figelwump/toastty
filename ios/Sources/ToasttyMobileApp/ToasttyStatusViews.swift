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

/// The app-wide activity spinner, matching the desktop app's
/// `SessionStatusIndicator`: a trimmed arc rotating once every 0.9 seconds.
struct ToasttySpinner: View {
    var size: CGFloat = 8
    var lineWidth: CGFloat = 1.5
    var color: Color = ToasttyDesignTokens.amber
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { context in
            Circle()
                .trim(from: 0.16, to: 0.9)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(reduceMotion ? .zero : angle(at: context.date))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func angle(at date: Date) -> Angle {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 0.9) / 0.9
        return .degrees(phase * 360)
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
            conversation.title,
            isVisible ? accessibilityLabel : conversation.state.accessibilityLabel,
            conversation.lastActivity,
            conversation.workspaceTitle,
            conversation.agent.displayName,
            conversation.cwd,
            conversation.displayAge,
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
