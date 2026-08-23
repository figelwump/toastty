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

    @ViewBuilder
    var body: some View {
        if bucket.isVisible {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(bucket.rawValue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(compact ? .caption2.monospaced() : .caption.monospaced())
            .foregroundStyle(statusColor)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bucket.rawValue)
        }
    }

    private var statusColor: Color {
        ToasttyDesignTokens.color(for: bucket)
    }
}

/// The app-wide activity spinner, matching the desktop app's
/// `SessionStatusIndicator`: a trimmed arc rotating once every 0.9 seconds.
struct ToasttySpinner: View {
    var size: CGFloat = 8
    var lineWidth: CGFloat = 1.5
    var color: Color = ToasttyDesignTokens.amber

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            Circle()
                .trim(from: 0.16, to: 0.9)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(angle(at: context.date))
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

/// Session-row status treatment: the working bucket swaps the dot for a
/// mini spinner so in-flight sessions read as live everywhere they appear.
/// The spinner occupies the same 8-point slot as the status dot so rows
/// keep a single text baseline.
struct ToasttySessionStatusLabel: View {
    let bucket: MobileSessionBucket

    @ViewBuilder
    var body: some View {
        if bucket == .working {
            HStack(spacing: 5) {
                ToasttySpinner(color: ToasttyDesignTokens.color(for: .working))
                Text(MobileSessionBucket.working.rawValue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.color(for: .working))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(MobileSessionBucket.working.rawValue)
        } else {
            ToasttyStatusLabel(bucket: bucket, compact: true)
        }
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
