import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain
import UIKit

/// A session in the Home and workspace lists, laid out like the desktop
/// sidebar row: a status rail, then the name over the summary. The path,
/// agent, model, and tab the old card showed live in the long-press card, as
/// they live in the desktop hover card.
struct ToasttySessionRow: View {
    let conversation: MobileConversation
    let freshness: LiveProjectionFreshness
    let accessibilityIdentifier: String
    /// The ⑂ chip, when this session spawned subspaces.
    var spawnerChip: ToasttySpawnerChip? = nil
    var isSpawnerFilterActive = false
    var onSpawnerChip: (ToasttySpawnerChip) -> Void = { _ in }
    /// Whether the Mac takes a flag change from this device now.
    var canFlag = false
    var onFlag: (Bool) -> Void = { _ in }
    let onOpen: (MobileConversation) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let laterFlagColor = Color(red: 185 / 255, green: 140 / 255, blue: 224 / 255)

    var body: some View {
        // The chip is its own button, so it sits over the row rather than
        // inside the row's label; the label reserves its space.
        ZStack(alignment: .bottomTrailing) {
            rowButton
            if let spawnerChip {
                Button {
                    onSpawnerChip(spawnerChip)
                } label: {
                    ToasttySpawnerChipLabel(
                        chip: spawnerChip,
                        isFilterActive: isSpawnerFilterActive,
                        freshness: freshness
                    )
                    // The visible chip is small; the button around it is a
                    // full-height touch target on the row's trailing edge.
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(minWidth: 44, minHeight: 32, alignment: .bottomTrailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(spawnerChip.accessibilityLabel)
                .accessibilityHint(isSpawnerFilterActive ? "Shows all task spaces" : "Shows only its task spaces")
                .accessibilityIdentifier("toastty-session-subspaces-\(conversation.id.uuidString)")
            }
        }
    }

    private var rowButton: some View {
        Button {
            onOpen(conversation)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // A blank line of the title font gives the rail the first
                // line's height, so the mark stays centered on it at every
                // text size. A standing flag sits under it, as on the desktop.
                VStack(spacing: 4) {
                    Text(" ")
                        .font(titleFont)
                        .frame(width: 12)
                        .overlay {
                            ToasttySessionRailMark(bucket: bucket, freshness: freshness)
                        }
                    if conversation.isFlaggedForLater {
                        ToasttyLaterFlagMark()
                    }
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    titleLine
                    summaryLine
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Self.shape)
        }
        .buttonStyle(ToasttySessionRowButtonStyle(tint: rowTint))
        .contextMenu {
            Button("Open", systemImage: "arrow.up.right") {
                onOpen(conversation)
            }
            if canFlag {
                Button(
                    ToasttySessionRowPresentation.flagActionTitle(isFlagged: conversation.isFlaggedForLater),
                    systemImage: conversation.isFlaggedForLater ? "flag.slash" : "flag"
                ) {
                    onFlag(!conversation.isFlaggedForLater)
                }
            }
            if let spawnerChip {
                Button(
                    isSpawnerFilterActive ? "Show All Task Spaces" : "Show Its Task Spaces",
                    systemImage: "arrow.triangle.branch"
                ) {
                    onSpawnerChip(spawnerChip)
                }
            }
            if let cwd = conversation.cwd {
                Button("Copy Path", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = cwd
                }
            }
        } preview: {
            ToasttySessionDetailCard(conversation: conversation, freshness: freshness)
        }
        .accessibilityLabel(statusPresentation.accessibilitySummary(for: conversation))
        .accessibilityHint("Opens the conversation. Touch and hold for details.")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    static let shape = RoundedRectangle(
        cornerRadius: ToasttyDesignTokens.controlCornerRadius,
        style: .continuous
    )

    private var bucket: MobileSessionBucket { conversation.state.bucket }

    private var statusPresentation: ToasttySessionStatusPresentation {
        ToasttySessionStatusPresentation(bucket: bucket, freshness: freshness)
    }

    @ViewBuilder
    private var titleLine: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Large text wraps the name and moves the badge and age to their
            // own line rather than squeezing the name to a few characters.
            VStack(alignment: .leading, spacing: 3) {
                titleText
                HStack(spacing: 6) { trailingFacts }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                titleText
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailingFacts
            }
        }
    }

    private var titleText: some View {
        Text(ToasttySessionRowPresentation.title(for: conversation))
            .font(titleFont)
            .foregroundStyle(ToasttyDesignTokens.primaryText)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var trailingFacts: some View {
        if let badge = ToasttySessionRowPresentation.badge(for: bucket) {
            Text(badge)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(statusColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
        }
        if isWorking, freshness == .live, conversation.turnElapsed != nil {
            // The turn's running time, ticking, in place of the age.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(conversation.elapsedTurnLabel(atMonotonicTime: ProcessInfo.processInfo.systemUptime) ?? "")
                    .font(.caption2.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .fixedSize()
                    .accessibilityIdentifier("toastty-session-elapsed-\(conversation.id.uuidString)")
            }
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(conversation.age)
                    .font(.caption2.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .fixedSize()
            }
        }
    }

    private var summaryLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(conversation.lastActivity)
                .font(isWorking ? .caption.monospaced().italic() : .caption.monospaced())
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let spawnerChip {
                // Holds the place of the chip button drawn over the row.
                ToasttySpawnerChipLabel(
                    chip: spawnerChip,
                    isFilterActive: isSpawnerFilterActive,
                    freshness: freshness
                )
                .hidden()
                .accessibilityHidden(true)
            }
        }
    }

    private var isWorking: Bool { bucket == .working }

    /// Rows that want the user read heavier, and working rows lean, as on
    /// the desktop sidebar.
    private var titleFont: Font {
        let font = Font.subheadline.weight(
            ToasttySessionRowPresentation.needsAttention(bucket) ? .bold : .medium
        )
        return isWorking ? font.italic() : font
    }

    private var statusColor: Color {
        freshness == .live ? ToasttyDesignTokens.color(for: bucket) : ToasttyDesignTokens.mutedText
    }

    /// The desktop sidebar's attention fills. Other rows sit on the page
    /// background, so only sessions that want the user stand out.
    private var rowTint: Color {
        switch bucket {
        case .ready: ToasttyDesignTokens.color(for: .ready).opacity(0.16)
        case .needsApproval: ToasttyDesignTokens.color(for: .needsApproval).opacity(0.13)
        case .error: ToasttyDesignTokens.color(for: .error).opacity(0.13)
        case .working, .idle: .clear
        }
    }
}

enum ToasttySessionRowPresentation {
    /// Every row keeps two lines. A session the provider has not named yet
    /// falls back to its agent, the desktop's placeholder.
    static func title(for conversation: MobileConversation) -> String {
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? conversation.agent.displayName : title
    }

    /// Ready rows get their tint and a heavy title but no badge, matching the
    /// desktop, so the badge is reserved for states that block or broke work.
    static func badge(for bucket: MobileSessionBucket) -> String? {
        switch bucket {
        case .needsApproval: "approval"
        case .error: "error"
        case .ready, .working, .idle: nil
        }
    }

    static func flagActionTitle(isFlagged: Bool) -> String {
        isFlagged ? "Clear Later Flag" : "Flag for Later"
    }

    static func needsAttention(_ bucket: MobileSessionBucket) -> Bool {
        switch bucket {
        case .needsApproval, .error, .ready: true
        case .working, .idle: false
        }
    }
}

struct ToasttySessionRowButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? ToasttyDesignTokens.raisedSurface : tint,
                in: ToasttySessionRow.shape
            )
    }
}

struct ToasttySpawnerChipLabel: View {
    let chip: ToasttySpawnerChip
    let isFilterActive: Bool
    let freshness: LiveProjectionFreshness

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.triangle.branch")
                .imageScale(.small)
            Text("\(chip.count)")
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(isFilterActive ? 0.3 : 0.14), in: shape)
        .overlay {
            if isFilterActive { shape.strokeBorder(color.opacity(0.7), lineWidth: 1) }
        }
        .fixedSize()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ToasttyDesignTokens.chipCornerRadius, style: .continuous)
    }

    private var color: Color {
        guard freshness == .live else { return ToasttyDesignTokens.mutedText }
        return switch chip.tone {
        case .neutral: ToasttyDesignTokens.secondaryText
        case .needsApproval: ToasttyDesignTokens.color(for: .needsApproval)
        case .error: ToasttyDesignTokens.color(for: .error)
        }
    }
}

extension View {
    /// The session row's swipe actions: Info always, and Flag while the Mac
    /// takes the change. Neither is a full swipe, since a full swipe would
    /// act on a row the user only meant to peek at.
    func toasttySessionSwipeActions(
        _ conversation: MobileConversation,
        controller: HomeScreenController,
        infoConversation: Binding<ToasttySessionInfoSelection?>
    ) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                infoConversation.wrappedValue = ToasttySessionInfoSelection(id: conversation.id)
            } label: {
                Label("Info", systemImage: "info.circle")
            }
            .tint(ToasttyDesignTokens.offline)
            .accessibilityIdentifier("toastty-session-swipe-info-\(conversation.id.uuidString)")
            if controller.canFlagConversations {
                Button {
                    controller.setConversationFlag(conversation.id, isFlagged: !conversation.isFlaggedForLater)
                } label: {
                    Label(
                        conversation.isFlaggedForLater ? "Unflag" : "Flag",
                        systemImage: conversation.isFlaggedForLater ? "flag.slash" : "flag"
                    )
                }
                .tint(ToasttySessionRow.laterFlagColor)
                .accessibilityIdentifier("toastty-session-swipe-flag-\(conversation.id.uuidString)")
            }
        }
    }
}

/// The desktop's violet "Flag for Later" mark.
struct ToasttyLaterFlagMark: View {
    var body: some View {
        Image(systemName: "flag.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(ToasttySessionRow.laterFlagColor)
    }
}

/// The status mark in a row's rail: a spinner while live work runs, a dot for
/// the other states that want attention, and nothing while idle. A stale
/// projection keeps the last-known mark but drops its color and motion.
struct ToasttySessionRailMark: View {
    let bucket: MobileSessionBucket
    let freshness: LiveProjectionFreshness

    var body: some View {
        let presentation = ToasttySessionStatusPresentation(bucket: bucket, freshness: freshness)
        if presentation.showsWorkingSpinner {
            ToasttySpinner(size: 9, color: color)
        } else if presentation.isVisible {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .background {
                    if bucket == .needsApproval, freshness == .live {
                        Circle()
                            .fill(color.opacity(0.22))
                            .frame(width: 13, height: 13)
                    }
                }
        }
    }

    private var color: Color {
        freshness == .live ? ToasttyDesignTokens.color(for: bucket) : ToasttyDesignTokens.mutedText
    }
}

/// The long-press card: the phone's version of the desktop session hover
/// card, built only from fields the Mac already sends.
struct ToasttySessionDetailCard: View {
    let conversation: MobileConversation
    let freshness: LiveProjectionFreshness

    private static let tabText = Color(red: 188 / 255, green: 208 / 255, blue: 245 / 255)
    private static let tabSurface = Color(red: 110 / 255, green: 150 / 255, blue: 230 / 255).opacity(0.2)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(" ")
                    .font(.headline)
                    .frame(width: 12)
                    .overlay {
                        ToasttySessionRailMark(bucket: conversation.state.bucket, freshness: freshness)
                    }
                Text(ToasttySessionRowPresentation.title(for: conversation))
                    .font(.headline)
                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                    .lineLimit(2)
            }
            Text(conversation.lastActivity)
                .font(.subheadline)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            divider
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                fact("status", statusText)
                if conversation.turnElapsed != nil, freshness == .live {
                    GridRow {
                        Text("elapsed").foregroundStyle(ToasttyDesignTokens.mutedText)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(conversation.elapsedTurnLabel(atMonotonicTime: ProcessInfo.processInfo.systemUptime) ?? "")
                                .foregroundStyle(ToasttyDesignTokens.primaryText)
                        }
                    }
                    .font(.caption.monospaced())
                }
                if let cwd = conversation.cwd {
                    // Long paths lose their front, so the worktree directory
                    // at the end stays readable, as in the desktop card.
                    fact("path", cwd, lineLimit: 1, truncation: .head)
                }
                if !conversation.displayAge.isEmpty {
                    fact("updated", conversation.displayAge)
                }
                if let profile = ToasttySessionExecutionProfilePresentation(
                    profile: conversation.executionProfile,
                    isLastReported: freshness != .live
                ) {
                    fact("model", profile.text)
                }
                if let lastTurn = conversation.lastTurnLabel {
                    fact("last turn", lastTurn)
                }
                if !conversation.workspaceTitle.isEmpty {
                    fact("workspace", conversation.workspaceTitle)
                }
                if conversation.isFlaggedForLater {
                    fact("flagged", "for later")
                }
            }
            divider
            HStack(spacing: 6) {
                if let tabTitle = conversation.workspaceTabTitle {
                    pill(tabTitle, foreground: Self.tabText, background: Self.tabSurface)
                }
                pill(
                    conversation.agent.displayName,
                    foreground: ToasttyDesignTokens.secondaryText,
                    background: ToasttyDesignTokens.chipSurface
                )
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(ToasttyDesignTokens.elevatedSurface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toastty-session-detail-card")
    }

    private var statusText: String {
        let presentation = ToasttySessionStatusPresentation(
            bucket: conversation.state.bucket,
            freshness: freshness
        )
        return presentation.isVisible ? presentation.label : conversation.state.accessibilityLabel
    }

    private var divider: some View {
        Rectangle()
            .fill(ToasttyDesignTokens.divider)
            .frame(height: 1)
    }

    /// Values wrap so a long model or workspace name stays whole; only the
    /// path is held to one line.
    private func fact(
        _ label: String,
        _ value: String,
        lineLimit: Int? = 3,
        truncation: Text.TruncationMode = .tail
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
            Text(value)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .lineLimit(lineLimit)
                .truncationMode(truncation)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.monospaced())
    }

    private func pill(_ text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.chipCornerRadius,
                style: .continuous
            ))
    }
}
