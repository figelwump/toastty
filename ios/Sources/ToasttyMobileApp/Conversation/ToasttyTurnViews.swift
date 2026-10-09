import SwiftUI
import ToasttyMobileDomain

/// Disclosure state for per-turn work sections. Settled turns fold by
/// default; the live turn streams expanded and auto-folds when its response
/// completes. Explicit user toggles win over automatic behavior.
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
    mutating func reconcile(
        turns: [ToasttyTranscriptTurn],
        settledIDs: Set<ToasttyTranscriptRowID>,
        revision: ToasttyTranscriptRevision,
        previousBoundarySequence: UInt64?
    ) {
        let currentIDs = Set(turns.map(\.id))

        switch revision {
        case .initial, .rebuilt:
            explicitlyToggledIDs.removeAll(keepingCapacity: true)
            expandedIDs = currentIDs.subtracting(settledIDs)
        case .appended, .metadataOnly:
            for turn in turns where explicitlyToggledIDs.contains(turn.id) == false {
                if settledIDs.contains(turn.id) {
                    // Covers both a newly settled live turn and settled turns
                    // revealed by an append.
                    expandedIDs.remove(turn.id)
                } else {
                    expandedIDs.insert(turn.id)
                }
            }
        case .prepended:
            for turn in turns where knownIDs.contains(turn.id) == false
                && explicitlyToggledIDs.contains(turn.id) == false {
                let reachesVisibleRegion = previousBoundarySequence.map { boundary in
                    turn.workBlockIDs.contains { $0.rowID.sequence >= boundary }
                } ?? false
                if settledIDs.contains(turn.id) == false || reachesVisibleRegion {
                    expandedIDs.insert(turn.id)
                }
            }
        }

        expandedIDs.formIntersection(currentIDs)
        explicitlyToggledIDs.formIntersection(currentIDs)
        knownIDs = currentIDs
    }
}

/// The quiet chip that stands in for (or heads) a turn's work section.
struct ToasttyTurnWorkStrip: View {
    let turn: ToasttyTranscriptTurn
    let isExpanded: Bool
    let isLive: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                if isLive {
                    ToasttySpinner(size: 9)
                } else {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(summary)
            }
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.mutedText)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(ToasttyDesignTokens.chipSurface)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ToasttyDesignTokens.chipBorder)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Collapses the work details" : "Expands the work details")
        .accessibilityIdentifier(
            "toastty-mobile-transcript-turn-\(turn.id.accessibilitySuffix)"
        )
    }

    private var summary: String {
        var parts: [String] = [isLive ? "working" : "worked"]
        if turn.toolCallCount > 0 {
            parts.append(turn.toolCallCount == 1 ? "1 tool call" : "\(turn.toolCallCount) tool calls")
        }
        if turn.noteCount > 0 {
            parts.append(turn.noteCount == 1 ? "1 note" : "\(turn.noteCount) notes")
        }
        return parts.joined(separator: " · ")
    }
}

/// What the transcript's tail shows while the agent works.
struct ToasttyTranscriptWorkingIndicator: Equatable {
    /// The running turn's age, when the host reports it.
    let turnElapsed: MobileActivityAge?

    func elapsedLabel(atMonotonicTime now: TimeInterval) -> String? {
        turnElapsed.map { MobileConversation.durationLabel(seconds: TimeInterval($0.seconds(atMonotonicTime: now))) }
    }
}

/// The in-chat working row at the live edge, below anything the agent has
/// already received. The turn's running time ticks as in the session list.
struct ToasttyTranscriptWorkingRow: View {
    let indicator: ToasttyTranscriptWorkingIndicator

    var body: some View {
        if indicator.turnElapsed != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                row(elapsed: indicator.elapsedLabel(atMonotonicTime: ProcessInfo.processInfo.systemUptime))
            }
        } else {
            row(elapsed: nil)
        }
    }

    private func row(elapsed: String?) -> some View {
        HStack(spacing: 8) {
            ToasttySpinner(size: 9)
            Text(["working", elapsed].compactMap { $0 }.joined(separator: " · "))
                .monospacedDigit()
        }
        .font(.caption2.monospaced())
        .foregroundStyle(ToasttyDesignTokens.mutedText)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent working")
        .accessibilityValue(elapsed ?? "")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("toastty-mobile-transcript-working")
    }
}
