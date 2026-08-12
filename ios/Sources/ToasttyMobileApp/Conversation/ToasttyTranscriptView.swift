import RemoteProtocol
import SwiftUI

struct ToasttyTranscriptView: View {
    let state: ToasttyConversationPresentationState
    let loadOlder: () -> Void

    @State private var expandedMessageIDs: Set<ToasttyTranscriptRowID> = []
    @State private var expandedToolBatchIDs: Set<ToasttyTranscriptRowID> = []
    @State private var expandedSubagentIDs: Set<ToasttyTranscriptRowID> = []
    @State private var isAtLiveEdge = true
    @State private var followsLiveEdge = true
    @State private var visibleBlockIDs: [ToasttyTranscriptRowID] = []

    init(
        state: ToasttyConversationPresentationState,
        loadOlder: @escaping () -> Void = {}
    ) {
        self.state = state
        self.loadOlder = loadOlder
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if showsStatusContent {
                    VStack(spacing: 8) {
                        statusContent
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .background(ToasttyDesignTokens.background)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        olderHistoryControl

                        ForEach(state.blocks) { block in
                            blockView(block)
                                .id(block.id)
                        }

                        if state.rows.isEmpty, state.phase != .loading {
                            ContentUnavailableView(
                                "No transcript yet",
                                systemImage: "text.bubble",
                                description: Text("New conversation activity will appear here.")
                            )
                            .foregroundStyle(ToasttyDesignTokens.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 44)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .background(ToasttyDesignTokens.background)
                .accessibilityIdentifier("toastty-mobile-transcript")
                .overlay(alignment: .topLeading) {
                    if state.rows.count == 5_000 {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityElement()
                            .accessibilityLabel("5,000 transcript rows ready")
                            .accessibilityIdentifier("toastty-mobile-transcript-ready-5000")
                    }
                }
                .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
                    TranscriptScrollMetrics(
                        offsetY: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        viewportHeight: geometry.containerSize.height
                    )
                } action: { old, new in
                    let atLiveEdge = new.distanceFromBottom < 72
                    isAtLiveEdge = atLiveEdge
                    if atLiveEdge {
                        followsLiveEdge = true
                    } else if abs(new.contentHeight - old.contentHeight) < 0.5,
                              abs(new.offsetY - old.offsetY) > 1 {
                        // Only user-driven offset changes disengage following.
                        // Content growth at the tail must not turn a reader who
                        // was already following into a slow-reader state.
                        followsLiveEdge = false
                    }
                }
                .onScrollTargetVisibilityChange(
                    idType: ToasttyTranscriptRowID.self,
                    threshold: 0.12
                ) { ids in
                    visibleBlockIDs = ids
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isAtLiveEdge == false, let target = state.blocks.last?.id {
                        HStack {
                            Spacer(minLength: 0)
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(target, anchor: .bottom)
                                }
                            } label: {
                                Label("Jump to latest", systemImage: "arrow.down")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(ToasttyDesignTokens.amber, in: Capsule())
                                    .foregroundStyle(Color(red: 22 / 255, green: 16 / 255, blue: 6 / 255))
                            }
                            .accessibilityIdentifier("toastty-mobile-transcript-jump-latest")
                        }
                        .padding(14)
                        .background(ToasttyDesignTokens.background)
                    }
                }
                .task(id: scrollChangeKey) {
                    await Task.yield()
                    // A second turn lets text layout settle before choosing the
                    // live-edge or preserved prepend anchor.
                    await Task.yield()
                    guard Task.isCancelled == false else { return }
                    switch state.revision {
                    case .initial, .rebuilt:
                        if let target = state.blocks.last?.id {
                            proxy.scrollTo(target, anchor: .bottom)
                        }
                    case .appended:
                        if followsLiveEdge, let target = state.blocks.last?.id {
                            proxy.scrollTo(target, anchor: .bottom)
                        }
                    case .prepended:
                        if let anchor = state.prependAnchorID ?? visibleBlockIDs.first {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                    case .metadataOnly:
                        break
                    }
                }
            }
            .background(ToasttyDesignTokens.background)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch state.phase {
        case .loading:
            HStack(spacing: 9) {
                ProgressView()
                    .tint(ToasttyDesignTokens.amber)
                Text("Loading transcript…")
            }
            .transcriptBannerStyle(color: ToasttyDesignTokens.secondaryText)
        case .resyncing:
            HStack(spacing: 9) {
                ProgressView()
                    .tint(ToasttyDesignTokens.amber)
                Text("Resyncing transcript…")
            }
            .transcriptBannerStyle(color: ToasttyDesignTokens.amberText)
            .accessibilityIdentifier("toastty-mobile-transcript-resyncing")
        case .stale:
            Label("Connection paused — transcript may be stale", systemImage: "wifi.slash")
                .transcriptBannerStyle(color: ToasttyDesignTokens.secondaryText)
                .accessibilityIdentifier("toastty-mobile-transcript-stale")
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .transcriptBannerStyle(color: ToasttyDesignTokens.red)
        case .live:
            EmptyView()
        }

        if state.historyTruncated {
            Label(
                "Earlier activity is no longer retained by Toastty",
                systemImage: "clock.badge.exclamationmark"
            )
            .transcriptBannerStyle(color: ToasttyDesignTokens.mutedText)
            .accessibilityIdentifier("toastty-mobile-transcript-history-truncated")
        }
    }

    private var showsStatusContent: Bool {
        state.phase != .live || state.historyTruncated
    }

    @ViewBuilder
    private var olderHistoryControl: some View {
        if state.isLoadingOlder {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(ToasttyDesignTokens.amber)
                Text("Loading earlier activity…")
            }
            .transcriptBannerStyle(color: ToasttyDesignTokens.secondaryText)
            .accessibilityIdentifier("toastty-mobile-transcript-loading-older")
        } else if state.hasOlder {
            Button(action: loadOlder) {
                Label("Load earlier activity", systemImage: "arrow.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.amberText)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(ToasttyDesignTokens.raisedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toastty-mobile-transcript-load-older")
        }
    }

    @ViewBuilder
    private func blockView(_ block: ToasttyTranscriptBlock) -> some View {
        switch block.content {
        case .row(let row):
            ToasttyTranscriptRowView(
                row: row,
                messageIsExpanded: expandedMessageIDs.contains(row.id),
                subagentIsExpanded: expandedSubagentIDs.contains(row.id),
                toggleMessageExpansion: { toggle(row.id, in: &expandedMessageIDs) },
                toggleSubagentExpansion: { toggle(row.id, in: &expandedSubagentIDs) }
            )
        case .toolBatch(let rows):
            ToasttyToolBatchView(
                rows: rows,
                isExpanded: expandedToolBatchIDs.contains(block.id),
                toggleExpansion: { toggle(block.id, in: &expandedToolBatchIDs) }
            )
        }
    }

    private var scrollChangeKey: ScrollChangeKey {
        ScrollChangeKey(
            revision: state.revision,
            count: state.blocks.count,
            firstID: state.blocks.first?.id,
            lastID: state.blocks.last?.id
        )
    }

    private func toggle(
        _ id: ToasttyTranscriptRowID,
        in values: inout Set<ToasttyTranscriptRowID>
    ) {
        if values.contains(id) {
            values.remove(id)
        } else {
            values.insert(id)
        }
    }
}

private struct TranscriptScrollMetrics: Equatable {
    let offsetY: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat

    var distanceFromBottom: CGFloat {
        contentHeight - offsetY - viewportHeight
    }
}

private struct ScrollChangeKey: Equatable {
    let revision: ToasttyTranscriptRevision
    let count: Int
    let firstID: ToasttyTranscriptRowID?
    let lastID: ToasttyTranscriptRowID?
}

private struct ToasttyTranscriptRowView: View {
    let row: ToasttyTranscriptRow
    let messageIsExpanded: Bool
    let subagentIsExpanded: Bool
    let toggleMessageExpansion: () -> Void
    let toggleSubagentExpansion: () -> Void

    @ViewBuilder
    var body: some View {
        switch row.content {
        case .interaction(let interaction):
            ToasttyInteractionCard(interaction: interaction)
                .accessibilityIdentifier(rowAccessibilityIdentifier)
                .overlay {
                    if interaction.state == .pending {
                        Color.clear
                            .accessibilityElement()
                            .accessibilityLabel(
                                "Read-only interaction, \(interaction.prompt), Respond on the desktop"
                            )
                            .accessibilityIdentifier("toastty-mobile-readonly-interaction")
                    }
                }
        default:
            rowContent
                .accessibilityIdentifier(rowAccessibilityIdentifier)
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        switch row.content {
        case .userMessage(let text, let origin):
            message(
                text: text,
                isUser: true,
                metadata: origin == .remote ? "sent remotely" : nil
            )
        case .assistantMessage(let text, let phase):
            message(
                text: text,
                isUser: false,
                metadata: phase == .commentary ? "commentary" : nil
            )
        case .statusChanged(let state, let availability):
            marker(icon: "circle.dotted", text: "\(state) · \(availability)")
        case .interaction:
            EmptyView()
        case .interactionResolved(_, let resolution):
            marker(icon: resolutionIcon(resolution), text: "interaction \(resolution.rawValue)")
        case .subagentSummary(let name, let phase, let detail):
            disclosureRow(
                icon: "person.2",
                title: "\(name) · \(subagentPhaseLabel(phase))",
                detail: detail,
                isExpanded: subagentIsExpanded,
                action: toggleSubagentExpansion
            )
        case .sessionBindingChanged(let reason):
            marker(icon: "link", text: bindingLabel(reason))
        case .toolStarted, .toolFinished:
            EmptyView()
        }
    }

    private var rowAccessibilityIdentifier: String {
        "toastty-mobile-transcript-row-\(row.id.accessibilitySuffix)"
    }

    private func message(text: String, isUser: Bool, metadata: String?) -> some View {
        let isLarge = Self.isLarge(text)
        let visibleText = isLarge && messageIsExpanded == false
            ? Self.collapsed(text)
            : text

        return VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
            if isUser {
                Text(visibleText)
                    .font(.body)
                    .foregroundStyle(Color(red: 240 / 255, green: 232 / 255, blue: 216 / 255))
                    .textSelection(.enabled)
            } else {
                ToasttyMarkdownText(text: visibleText)
            }

            if isLarge {
                Button(messageIsExpanded ? "Show less" : "Show more", action: toggleMessageExpansion)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.amberText)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("toastty-mobile-transcript-expand-\(row.id.accessibilitySuffix)")
            }

            if let metadata {
                Text(metadata)
                    .font(.caption2.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
            }
        }
        .padding(isUser ? 12 : 0)
        .background(isUser ? Color(red: 58 / 255, green: 46 / 255, blue: 20 / 255) : .clear)
        .overlay {
            if isUser {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(red: 85 / 255, green: 67 / 255, blue: 29 / 255))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: isUser ? 340 : .infinity, alignment: isUser ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }

    private func marker(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.mutedText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
    }

    private func disclosureRow(
        icon: String,
        title: String,
        detail: String?,
        isExpanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                    Text(title)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .font(.caption.monospaced())
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityIdentifier("toastty-mobile-transcript-subagent-\(row.id.accessibilitySuffix)")

            if isExpanded, let detail, detail.isEmpty == false {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .textSelection(.enabled)
            }
        }
    }

    private static func isLarge(_ text: String) -> Bool {
        text.count > 1_400 || text.lazy.filter { $0 == "\n" }.prefix(20).count == 20
    }

    private static func collapsed(_ text: String) -> String {
        String(text.prefix(1_200)) + "…"
    }

    private func subagentPhaseLabel(_ phase: ConversationSubagentPhase) -> String {
        switch phase {
        case .started: "started"
        case .updated: "updated"
        case .finished: "finished"
        case .unknown: "activity"
        }
    }

    private func bindingLabel(_ reason: ConversationBindingChangeReason) -> String {
        switch reason {
        case .runtimeBound: "session connected"
        case .runtimeResumed: "session resumed"
        case .runtimeEnded: "session disconnected"
        case .projectionRebuilt: "transcript rebuilt"
        }
    }

    private func resolutionIcon(_ resolution: RemotePendingInteraction.State) -> String {
        switch resolution {
        case .pending: "hourglass"
        case .resolved: "checkmark.circle"
        case .superseded: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}

private struct ToasttyMarkdownText: View {
    let text: String

    var body: some View {
        Group {
            if let attributed = try? AttributedString(markdown: text) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(.body)
        .foregroundStyle(ToasttyDesignTokens.primaryText)
        .lineSpacing(3)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ToasttyToolBatchView: View {
    let rows: [ToasttyTranscriptRow]
    let isExpanded: Bool
    let toggleExpansion: () -> Void

    private var callCount: Int {
        Set(rows.compactMap(\.toolCallID)).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: toggleExpansion) {
                HStack(spacing: 7) {
                    Text(isExpanded ? "▾" : "▸")
                    Text(callCount == 1 ? "1 tool call" : "\(callCount) tool calls")
                    Spacer(minLength: 4)
                }
                .font(.caption.monospaced())
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityIdentifier("toastty-mobile-transcript-tool-\(rows[0].id.accessibilitySuffix)")

            if isExpanded {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: row.toolIcon)
                            .foregroundStyle(row.toolColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.toolSummary)
                                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                            if let detail = row.toolDetail, detail.isEmpty == false {
                                Text(detail)
                                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                                    .lineLimit(6)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption2.monospaced())
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("toastty-mobile-transcript-row-\(row.id.accessibilitySuffix)")
                }
            }
        }
    }
}

private struct ToasttyInteractionCard: View {
    let interaction: RemotePendingInteraction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Label(kindLabel, systemImage: kindIcon)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(accentColor)
                Spacer(minLength: 6)
                Text(interaction.state.rawValue)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(stateColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(stateColor.opacity(0.12), in: Capsule())
            }

            Text(interaction.prompt)
                .font(.body)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if interaction.options.isEmpty == false {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(interaction.options, id: \.id) { option in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle")
                                .font(.caption2)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(.subheadline.weight(.medium))
                                if let detail = option.detail {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                                }
                            }
                        }
                        .foregroundStyle(ToasttyDesignTokens.secondaryText)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if interaction.state == .pending {
                Label("Respond on the desktop", systemImage: "desktopcomputer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.amberText)
            }
        }
        .padding(14)
        .background(Color(red: 24 / 255, green: 21 / 255, blue: 9 / 255))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(accentColor.opacity(0.35))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var kindLabel: String {
        switch interaction.kind {
        case .permission: "Permission request"
        case .question: "Question"
        case .structuredChoice: "Choose on Mac"
        case .freeForm: "Response requested"
        }
    }

    private var kindIcon: String {
        switch interaction.kind {
        case .permission: "lock.shield"
        case .question: "questionmark.bubble"
        case .structuredChoice: "list.bullet.circle"
        case .freeForm: "text.bubble"
        }
    }

    private var accentColor: Color {
        interaction.state == .pending ? ToasttyDesignTokens.amber : ToasttyDesignTokens.secondaryText
    }

    private var stateColor: Color {
        switch interaction.state {
        case .pending: ToasttyDesignTokens.amberText
        case .resolved: ToasttyDesignTokens.green
        case .superseded: ToasttyDesignTokens.mutedText
        }
    }
}

private extension ToasttyTranscriptRow {
    var toolCallID: String? {
        switch content {
        case .toolStarted(let callID, _, _), .toolFinished(let callID, _, _, _): callID
        default: nil
        }
    }

    var toolSummary: String {
        switch content {
        case .toolStarted(_, let name, _): "\(name) · running"
        case .toolFinished(_, let name, let outcome, _): "\(name) · \(outcome.rawValue)"
        default: "Tool activity"
        }
    }

    var toolDetail: String? {
        switch content {
        case .toolStarted(_, _, let detail), .toolFinished(_, _, _, let detail): detail
        default: nil
        }
    }

    var toolIcon: String {
        switch content {
        case .toolStarted: "play.circle"
        case .toolFinished(_, _, let outcome, _): outcome == .failed ? "xmark.circle" : "checkmark.circle"
        default: "wrench"
        }
    }

    var toolColor: Color {
        switch content {
        case .toolFinished(_, _, .failed, _): ToasttyDesignTokens.red
        case .toolFinished(_, _, .succeeded, _): ToasttyDesignTokens.green
        default: ToasttyDesignTokens.mutedText
        }
    }
}

private extension View {
    func transcriptBannerStyle(color: Color) -> some View {
        self
            .font(.caption.monospaced())
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ToasttyDesignTokens.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .combine)
    }
}
