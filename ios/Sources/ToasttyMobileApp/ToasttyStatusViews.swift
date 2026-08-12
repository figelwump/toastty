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

struct ToasttyStatusLabel: View {
    let bucket: MobileSessionBucket
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            statusDot
            Text(bucket.rawValue)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(compact ? .caption2.monospaced() : .caption.monospaced())
        .foregroundStyle(bucket == .offline ? ToasttyDesignTokens.mutedText : statusColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bucket.rawValue)
    }

    @ViewBuilder
    private var statusDot: some View {
        if bucket == .offline {
            Circle()
                .stroke(statusColor, lineWidth: 1.5)
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
        }
    }

    private var statusColor: Color {
        ToasttyDesignTokens.color(for: bucket)
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
