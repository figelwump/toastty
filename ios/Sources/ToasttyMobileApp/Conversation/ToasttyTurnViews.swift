import SwiftUI

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
                    ProgressView()
                        .controlSize(.mini)
                        .tint(ToasttyDesignTokens.amber)
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
