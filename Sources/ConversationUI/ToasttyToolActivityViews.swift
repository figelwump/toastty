import RemoteProtocol
import SwiftUI

struct ToasttyToolBatchActivity: Equatable {
    let id: ToasttyTranscriptBlockID
    let lastSequence: UInt64

    static func make(from blocks: [ToasttyTranscriptBlock]) -> [Self] {
        blocks.compactMap { block in
            guard case .toolBatch(let rows) = block.content,
                  let lastSequence = rows.last?.id.sequence else { return nil }
            return Self(id: block.id, lastSequence: lastSequence)
        }
    }
}

/// Tool batches stay collapsed until the user opens them — live activity
/// keeps its count updating in the header without expanding, which stays
/// quiet inside an already-expanded working turn.
struct ToasttyToolBatchDisclosureState: Equatable {
    private(set) var expandedIDs: Set<ToasttyTranscriptBlockID> = []

    func isExpanded(_ id: ToasttyTranscriptBlockID) -> Bool {
        expandedIDs.contains(id)
    }

    mutating func toggle(_ id: ToasttyTranscriptBlockID) {
        if expandedIDs.remove(id) == nil {
            expandedIDs.insert(id)
        }
    }

    mutating func reconcile(
        activity: [ToasttyToolBatchActivity],
        revision: ToasttyTranscriptRevision
    ) {
        switch revision {
        case .initial, .rebuilt:
            expandedIDs.removeAll(keepingCapacity: true)
        case .appended, .prepended, .metadataOnly:
            break
        }
        expandedIDs.formIntersection(activity.map(\.id))
    }
}

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

/// One tool call: its start and its end, which are two events.
struct ToasttyToolCall: Identifiable, Equatable, Sendable {
    /// The call's ID, or the row's for an event without one.
    let id: String
    let name: String
    /// `nil` while the call runs.
    let outcome: ConversationToolOutcome?
    /// What the call did, such as its command, then what its end said.
    let details: [String]

    /// The calls in the order they started. A call's end updates its line.
    static func calls(in rows: [ToasttyTranscriptRow]) -> [ToasttyToolCall] {
        var calls: [ToasttyToolCall] = []
        var indexByID: [String: Int] = [:]
        for row in rows {
            let callID: String
            let name: String
            let outcome: ConversationToolOutcome?
            let detail: String?
            switch row.content {
            case .toolStarted(let id, let started, let startedDetail):
                (callID, name, outcome, detail) = (id, started, nil, startedDetail)
            case .toolFinished(let id, let finished, let result, let finishedDetail):
                (callID, name, outcome, detail) = (id, finished, result, finishedDetail)
            default:
                continue
            }
            let newDetails = [detail].compactMap { $0 }.filter { $0.isEmpty == false }
            if let index = indexByID[callID] {
                let previous = calls[index]
                calls[index] = ToasttyToolCall(
                    id: previous.id,
                    name: previous.name,
                    outcome: outcome ?? previous.outcome,
                    details: previous.details + newDetails.filter { previous.details.contains($0) == false }
                )
            } else {
                indexByID[callID] = calls.count
                calls.append(ToasttyToolCall(id: callID, name: name, outcome: outcome, details: newDetails))
            }
        }
        return calls
    }

    /// The calls of each tool batch, as the whole transcript tells them. A
    /// call shows in the batch where it starts, with its end also when the
    /// end comes in a later batch, such as after an approval. A batch whose
    /// calls all started earlier lists none.
    static func callsByBlock(_ blocks: [ToasttyTranscriptBlock]) -> [ToasttyTranscriptBlockID: [ToasttyToolCall]] {
        let batches = blocks.compactMap { block -> (id: ToasttyTranscriptBlockID, rows: [ToasttyTranscriptRow])? in
            guard case .toolBatch(let rows) = block.content else { return nil }
            return (block.id, rows)
        }
        guard batches.isEmpty == false else { return [:] }
        let whole = Dictionary(
            calls(in: batches.flatMap(\.rows)).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var shown: Set<String> = []
        var result: [ToasttyTranscriptBlockID: [ToasttyToolCall]] = [:]
        for batch in batches {
            result[batch.id] = calls(in: batch.rows).compactMap { call in
                shown.insert(call.id).inserted ? whole[call.id] ?? call : nil
            }
        }
        return result
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
