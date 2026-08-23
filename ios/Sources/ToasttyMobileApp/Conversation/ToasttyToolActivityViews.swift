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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ToasttyDesignTokens.amberText)
                        .frame(width: 30, height: 30)
                        .background(ToasttyDesignTokens.amber.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(callCount == 1 ? "1 tool call" : "\(callCount) tool calls")
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(ToasttyDesignTokens.secondaryText)
                        Text(isExpanded ? "Hide details" : "Show details")
                            .font(.caption2.monospaced())
                            .foregroundStyle(ToasttyDesignTokens.mutedText)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
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
                    .overlay(ToasttyDesignTokens.border)

                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        ToasttyToolEventRow(row: row)
                    }
                }
                .padding(12)
            }
        }
        .background(ToasttyDesignTokens.raisedSurface)
        .overlay {
            RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.controlCornerRadius,
                style: .continuous
            )
            .stroke(ToasttyDesignTokens.border)
        }
        .clipShape(RoundedRectangle(
            cornerRadius: ToasttyDesignTokens.controlCornerRadius,
            style: .continuous
        ))
    }
}

private struct ToasttyToolEventRow: View {
    let row: ToasttyTranscriptRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.toolIcon)
                .font(.body)
                .foregroundStyle(row.toolColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                Text(row.toolSummary)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                if let detail = row.toolDetail, detail.isEmpty == false {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(ToasttyDesignTokens.raisedSurface)
        .overlay {
            RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.controlCornerRadius,
                style: .continuous
            )
            .stroke(ToasttyDesignTokens.border)
        }
        .clipShape(RoundedRectangle(
            cornerRadius: ToasttyDesignTokens.controlCornerRadius,
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
        case .toolFinished(_, _, .failed, _): ToasttyDesignTokens.red
        case .toolFinished(_, _, .succeeded, _): ToasttyDesignTokens.green
        default: ToasttyDesignTokens.mutedText
        }
    }
}
