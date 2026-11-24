import RemoteProtocol
import SwiftUI

struct ToasttyToolBatchCard: View {
    let blockID: ToasttyTranscriptBlockID
    let rows: [ToasttyTranscriptRow]
    let isExpanded: Bool
    let toggleDetails: () -> Void

    private var callCount: Int {
        Set(rows.compactMap(\.toolCallID)).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleDetails) {
                HStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                        .conversationFont(.caption, weight: .semibold)
                        .foregroundStyle(ConversationDesignTokens.amberText)
                        .frame(width: 30, height: 30)
                        .background(ConversationDesignTokens.amber.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(callCount == 1 ? "1 tool call" : "\(callCount) tool calls")
                            .conversationFont(.caption, weight: .semibold, monospaced: true)
                            .foregroundStyle(ConversationDesignTokens.secondaryText)
                        Text(isExpanded ? "Hide details" : "Show details")
                            .conversationFont(.caption2, monospaced: true)
                            .foregroundStyle(ConversationDesignTokens.mutedText)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .conversationFont(.caption, weight: .semibold)
                        .foregroundStyle(ConversationDesignTokens.mutedText)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(callCount == 1 ? "1 tool call" : "\(callCount) tool calls")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses tool details" : "Expands tool details")
            .accessibilityIdentifier(
                "toastty-mobile-transcript-tool-\(blockID.accessibilitySuffix)"
            )

            if isExpanded {
                Divider()
                    .overlay(ConversationDesignTokens.border)

                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        ToasttyToolEventRow(row: row)
                    }
                }
                .padding(12)
            }
        }
        .background(ConversationDesignTokens.raisedSurface)
        .overlay {
            RoundedRectangle(
                cornerRadius: ConversationDesignTokens.controlCornerRadius,
                style: .continuous
            )
            .stroke(ConversationDesignTokens.border)
        }
        .clipShape(RoundedRectangle(
            cornerRadius: ConversationDesignTokens.controlCornerRadius,
            style: .continuous
        ))
    }
}

/// A batch's tool calls as one line each, for a transcript whose running
/// work folds (`ToasttyTranscriptOptions.foldsRunningWork`). The turn's
/// line is already the fold, so the calls show without a card of their
/// own. A click on a call that has details shows them.
struct ToasttyToolCallList: View {
    let blockID: ToasttyTranscriptBlockID
    /// The calls that start in this batch (`ToasttyToolCall.callsByBlock`).
    let calls: [ToasttyToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(calls) { call in
                ToasttyToolCallLine(call: call)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toastty-transcript-tool-calls-\(blockID.accessibilitySuffix)")
    }
}

private struct ToasttyToolCallLine: View {
    let call: ToasttyToolCall
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if call.details.isEmpty {
                line
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
            } else {
                Button {
                    showsDetails.toggle()
                } label: {
                    line
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")
            }

            if showsDetails {
                Text(call.details.joined(separator: "\n"))
                    .conversationFont(.caption2, monospaced: true)
                    .foregroundStyle(ConversationDesignTokens.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
            }
        }
    }

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon)
                .conversationFont(size: 9, weight: .semibold)
                .foregroundStyle(color)
                .frame(width: 10)
            Text(call.name)
                .fontWeight(.semibold)
                .foregroundStyle(ConversationDesignTokens.secondaryText)
            if let first = call.details.first {
                Text(firstLine(of: first))
                    .foregroundStyle(ConversationDesignTokens.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .conversationFont(.caption2, monospaced: true)
        .contentShape(Rectangle())
    }

    private var accessibilityLabel: String {
        ([call.name, outcomeLabel] + call.details.prefix(1)).joined(separator: ", ")
    }

    private func firstLine(of text: String) -> String {
        String(text.prefix { $0.isNewline == false })
    }

    private var icon: String {
        switch call.outcome {
        case nil: "circle.dotted"
        case .succeeded?: "checkmark"
        case .failed?: "xmark"
        case .unknown?: "circle"
        }
    }

    private var color: Color {
        switch call.outcome {
        case .succeeded?: ConversationDesignTokens.green
        case .failed?: ConversationDesignTokens.red
        case nil, .unknown?: ConversationDesignTokens.mutedText
        }
    }

    private var outcomeLabel: String {
        switch call.outcome {
        case nil: "running"
        case .succeeded?: "succeeded"
        case .failed?: "failed"
        case .unknown?: "finished"
        }
    }
}

private struct ToasttyToolEventRow: View {
    let row: ToasttyTranscriptRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.toolIcon)
                .conversationFont(.body)
                .foregroundStyle(row.toolColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                Text(row.toolSummary)
                    .conversationFont(.caption, weight: .semibold, monospaced: true)
                    .foregroundStyle(ConversationDesignTokens.secondaryText)
                if let detail = row.toolDetail, detail.isEmpty == false {
                    Text(detail)
                        .conversationFont(.caption, monospaced: true)
                        .foregroundStyle(ConversationDesignTokens.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(ConversationDesignTokens.raisedSurface)
        .overlay {
            RoundedRectangle(
                cornerRadius: ConversationDesignTokens.controlCornerRadius,
                style: .continuous
            )
            .stroke(ConversationDesignTokens.border)
        }
        .clipShape(RoundedRectangle(
            cornerRadius: ConversationDesignTokens.controlCornerRadius,
            style: .continuous
        ))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toastty-mobile-transcript-row-\(row.id.accessibilitySuffix)")
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
        case .toolFinished(_, _, let outcome, _):
            outcome == .failed ? "xmark.circle" : "checkmark.circle"
        default: "wrench"
        }
    }

    var toolColor: Color {
        switch content {
        case .toolFinished(_, _, .failed, _): ConversationDesignTokens.red
        case .toolFinished(_, _, .succeeded, _): ConversationDesignTokens.green
        default: ConversationDesignTokens.mutedText
        }
    }
}
