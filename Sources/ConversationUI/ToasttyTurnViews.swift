import RemoteProtocol
import SwiftUI

/// The look of a line that opens and closes: a digest's line and a row of
/// quiet checks. With `showsSpinner`, the line shows that the agent works
/// and has no chevron.
struct ToasttyDisclosureLineLabel: View {
    let text: String
    let isExpanded: Bool
    var showsSpinner = false

    var body: some View {
        HStack(spacing: 6) {
            if showsSpinner {
                ToasttySpinner(size: 9)
            }
            Text(text)
                .monospacedDigit()
            if showsSpinner == false {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .conversationFont(.caption2, weight: .semibold)
            }
        }
        .conversationFont(.caption)
        .foregroundStyle(ConversationDesignTokens.mutedText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// The one line of a row of quiet checks. Open, each check's own line shows
/// under it.
struct ToasttyQuietChecksLine: View {
    let run: ToasttyQuietCheckRun
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ToasttyDisclosureLineLabel(text: summary, isExpanded: isExpanded)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides the checks" : "Shows each check")
        .accessibilityIdentifier("toastty-mobile-transcript-quiet-checks-\(run.id.accessibilitySuffix)")
    }

    private var summary: String {
        CoordinatorDigestFold.quietChecksSummary(count: run.checks.count, timeRange: run.timeRangeText())
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
