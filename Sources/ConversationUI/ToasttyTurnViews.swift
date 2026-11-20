import SwiftUI

/// Disclosure state for per-turn work sections. Settled turns fold by
/// default; the live turn streams expanded and auto-folds when its response
/// completes, unless the host folds running work too
/// (`ToasttyTranscriptOptions.foldsRunningWork`). Explicit user toggles win
/// over automatic behavior.
struct ToasttyTurnFoldState: Equatable {
    private(set) var expandedIDs: Set<ToasttyTranscriptRowID> = []
    private var explicitlyToggledIDs: Set<ToasttyTranscriptRowID> = []
    private var knownIDs: Set<ToasttyTranscriptRowID> = []

    func isExpanded(_ id: ToasttyTranscriptRowID) -> Bool {
        expandedIDs.contains(id)
    }

    mutating func toggle(_ id: ToasttyTranscriptRowID) {
        explicitlyToggledIDs.insert(id)
        if expandedIDs.remove(id) == nil {
            expandedIDs.insert(id)
        }
    }

    /// - Parameters:
    ///   - settledIDs: turns whose work may fold (response complete and the
    ///     session is no longer working on them).
    ///   - previousBoundarySequence: on `.prepended`, the first row sequence
    ///     that was already on screen before the update. A newly grouped turn
    ///     whose work reaches into the previously visible region stays
    ///     expanded so the reader's anchor cannot vanish into a fold.
    ///   - opensRunningTurns: a turn that still runs shows its work. `false`
    ///     keeps every turn folded until the reader opens it.
    mutating func reconcile(
        turns: [ToasttyTranscriptTurn],
        settledIDs: Set<ToasttyTranscriptRowID>,
        revision: ToasttyTranscriptRevision,
        previousBoundarySequence: UInt64?,
        opensRunningTurns: Bool = true
    ) {
        let currentIDs = Set(turns.map(\.id))
        func opens(_ turn: ToasttyTranscriptTurn) -> Bool {
            opensRunningTurns && settledIDs.contains(turn.id) == false
        }

        switch revision {
        case .initial, .rebuilt:
            explicitlyToggledIDs.removeAll(keepingCapacity: true)
            expandedIDs = Set(turns.filter(opens).map(\.id))
        case .appended, .metadataOnly:
            for turn in turns where explicitlyToggledIDs.contains(turn.id) == false {
                // Covers both a newly settled live turn and settled turns
                // revealed by an append.
                if opens(turn) {
                    expandedIDs.insert(turn.id)
                } else {
                    expandedIDs.remove(turn.id)
                }
            }
        case .prepended:
            for turn in turns where knownIDs.contains(turn.id) == false
                && explicitlyToggledIDs.contains(turn.id) == false {
                let reachesVisibleRegion = previousBoundarySequence.map { boundary in
                    turn.workBlockIDs.contains { $0.rowID.sequence >= boundary }
                } ?? false
                if opens(turn) {
                    expandedIDs.insert(turn.id)
                } else if reachesVisibleRegion {
                    // The reader sees this work: it stays open, as after
                    // the reader's own toggle, also when later updates
                    // come.
                    expandedIDs.insert(turn.id)
                    explicitlyToggledIDs.insert(turn.id)
                }
            }
        }

        expandedIDs.formIntersection(currentIDs)
        explicitlyToggledIDs.formIntersection(currentIDs)
        knownIDs = currentIDs
    }
}

/// The quiet chip that stands in for (or heads) a turn's work section.
///
/// The transcript shows that the agent works in one place only: at the end
/// of the running turn. When the turn's work is folded, this chip is that
/// end and carries the spinner and the running time (`workingIndicator`).
/// When the work is open, the working row under it does, and the chip only
/// counts the work.
struct ToasttyTurnWorkStrip: View {
    let turn: ToasttyTranscriptTurn
    let isExpanded: Bool
    let isLive: Bool
    /// Set when this chip shows that the agent works.
    var workingIndicator: ToasttyTranscriptWorkingIndicator?
    let toggle: () -> Void

    var body: some View {
        if turn.workBlockIDs.isEmpty {
            // A running turn before its first work: nothing to open yet.
            chip
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary(elapsed: nil))
                .accessibilityIdentifier(
                    "toastty-mobile-transcript-turn-\(turn.id.accessibilitySuffix)"
                )
        } else {
            Button(action: toggle) {
                chip
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary(elapsed: nil))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses the work details" : "Expands the work details")
            .accessibilityIdentifier(
                "toastty-mobile-transcript-turn-\(turn.id.accessibilitySuffix)"
            )
        }
    }

    @ViewBuilder
    private var chip: some View {
        if let workingIndicator {
            ToasttyWorkingTime(indicator: workingIndicator) { elapsed in
                ToasttyWorkingChip(text: summary(elapsed: elapsed)) {
                    ToasttySpinner(size: 9)
                }
            }
        } else {
            ToasttyWorkingChip(text: summary(elapsed: nil)) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .conversationFont(size: 9, weight: .semibold)
            }
        }
    }

    /// "working · 16s · 2 tool calls" while it shows that the agent works,
    /// "2 tool calls · 1 note" while the turn runs with its work open, and
    /// "worked · 2 tool calls" after the turn.
    private func summary(elapsed: String?) -> String {
        var counts: [String] = []
        if turn.toolCallCount > 0 {
            counts.append(turn.toolCallCount == 1 ? "1 tool call" : "\(turn.toolCallCount) tool calls")
        }
        if turn.noteCount > 0 {
            counts.append(turn.noteCount == 1 ? "1 note" : "\(turn.noteCount) notes")
        }
        let lead: [String]
        if workingIndicator != nil {
            lead = ["working", elapsed].compactMap { $0 }
        } else if isLive {
            lead = counts.isEmpty ? ["working"] : []
        } else {
            lead = ["worked"]
        }
        return (lead + counts).joined(separator: " · ")
    }
}

/// The one place that shows that the agent works: the end of the running
/// turn.
enum ToasttyTranscriptWorkingLine: Equatable {
    /// The agent does not work, or the transcript is not live.
    case none
    /// The running turn's own line: its work strip, or the line of the
    /// host's message that started it. Its work is folded, so the line is
    /// the turn's end.
    case turn(ToasttyTranscriptRowID)
    /// The line of a host's message that was typed and is not in the
    /// transcript yet. Its row's line takes over when it comes.
    case send(String)
    /// The working row at the end of the chat.
    case row

    /// - Parameters:
    ///   - isWorking: the agent works and the transcript is live.
    ///   - foldsRunningWork: `ToasttyTranscriptOptions.foldsRunningWork`.
    ///   - liveTurn: the transcript's last turn, while it is not settled.
    ///   - isLiveTurnExpanded: the reader opened that turn's work.
    static func place(
        isWorking: Bool,
        foldsRunningWork: Bool,
        sendItems: [ToasttySendPresentationItem],
        liveTurn: ToasttyTranscriptTurn?,
        isLiveTurnExpanded: Bool
    ) -> Self {
        guard isWorking else { return .none }
        guard foldsRunningWork else { return .row }
        // A message that was typed and is not in the transcript yet shows
        // after it. A receipt of a send that failed is not part of a turn.
        if let sent = sendItems.last(where: { item in
            if case .optimistic = item.content { return true }
            return false
        }) {
            return sent.hostMessage?.isLine == true ? .send(sent.clientRequestID) : .row
        }
        // Only a turn without its answer surely is the one that runs. After
        // the answer, the agent works on a message that the transcript
        // does not show yet, such as a digest that another device sees
        // typed, or goes on after an answer without a phase. An open turn
        // ends with its work. In each case the row at the end is the end.
        if let liveTurn, liveTurn.hasResponse == false, isLiveTurnExpanded == false {
            return .turn(liveTurn.id)
        }
        return .row
    }
}

/// The chip's look, shared by the turn's strip and the working row of a
/// transcript whose running work folds, so that one can take the other's
/// place without a change on screen.
struct ToasttyWorkingChip<Mark: View>: View {
    let text: String
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        HStack(spacing: 8) {
            mark()
            Text(text)
                .monospacedDigit()
        }
        .conversationFont(.caption2, monospaced: true)
        .foregroundStyle(ConversationDesignTokens.mutedText)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(ConversationDesignTokens.chipSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(ConversationDesignTokens.chipBorder)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Draws its content with the running turn's time, such as "16s", and
/// again each second. `nil` when the host does not know the turn's age.
struct ToasttyWorkingTime<Content: View>: View {
    let indicator: ToasttyTranscriptWorkingIndicator
    @ViewBuilder let content: (String?) -> Content

    var body: some View {
        if indicator.turnElapsed != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                content(indicator.elapsedLabel(atMonotonicTime: ProcessInfo.processInfo.systemUptime))
            }
        } else {
            content(nil)
        }
    }
}

/// What the transcript's tail shows while the agent works.
public struct ToasttyTranscriptWorkingIndicator: Equatable, Sendable {
    /// A turn's age as the host reported it, anchored to the local monotonic
    /// clock so wall-clock changes cannot move it.
    public struct TurnElapsed: Equatable, Sendable {
        public let secondsAtReceipt: Int
        public let receivedAtMonotonicTime: TimeInterval

        public init(secondsAtReceipt: Int, receivedAtMonotonicTime: TimeInterval) {
            self.secondsAtReceipt = max(0, secondsAtReceipt)
            self.receivedAtMonotonicTime = receivedAtMonotonicTime.isFinite
                ? max(0, receivedAtMonotonicTime)
                : 0
        }

        /// Whole seconds elapsed, advanced only from the monotonic anchor.
        func seconds(atMonotonicTime now: TimeInterval) -> Int {
            let finiteNow = now.isFinite ? now : receivedAtMonotonicTime
            return secondsAtReceipt + max(0, Int(finiteNow - receivedAtMonotonicTime))
        }
    }

    /// The running turn's age, when the host reports it.
    public let turnElapsed: TurnElapsed?

    public init(turnElapsed: TurnElapsed?) {
        self.turnElapsed = turnElapsed
    }

    func elapsedLabel(atMonotonicTime now: TimeInterval) -> String? {
        turnElapsed.map { Self.durationLabel(seconds: $0.seconds(atMonotonicTime: now)) }
    }

    /// Durations past this show as this, as in the iPhone session list.
    static let maximumDurationSeconds = 100 * 365 * 24 * 60 * 60

    /// The same format as the iPhone session list: "42s", then "3m 07s".
    static func durationLabel(seconds: Int) -> String {
        let clamped = min(max(0, seconds), maximumDurationSeconds)
        let minutes = clamped / 60
        let remaining = clamped % 60
        guard minutes > 0 else { return "\(remaining)s" }
        return String(format: "%dm %02ds", minutes, remaining)
    }
}

/// The in-chat working row at the live edge, below anything the agent has
/// already received. The turn's running time ticks as in the session list.
/// Where the running work folds, it has the turn strip's look: the strip
/// takes its place once the turn's message is in the transcript.
struct ToasttyTranscriptWorkingRow: View {
    let indicator: ToasttyTranscriptWorkingIndicator
    var looksLikeStrip = false

    var body: some View {
        ToasttyWorkingTime(indicator: indicator) { elapsed in
            row(elapsed: elapsed)
        }
    }

    @ViewBuilder
    private func content(text: String) -> some View {
        if looksLikeStrip {
            ToasttyWorkingChip(text: text) { ToasttySpinner(size: 9) }
        } else {
            HStack(spacing: 8) {
                ToasttySpinner(size: 9)
                Text(text)
                    .monospacedDigit()
            }
            .conversationFont(.caption2, monospaced: true)
            .foregroundStyle(ConversationDesignTokens.mutedText)
            .padding(.vertical, 6)
        }
    }

    private func row(elapsed: String?) -> some View {
        content(text: ["working", elapsed].compactMap { $0 }.joined(separator: " · "))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Agent working")
            .accessibilityValue(elapsed ?? "")
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("toastty-mobile-transcript-working")
    }
}
