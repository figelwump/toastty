import SwiftUI

struct ToasttyToolBatchSelection: Identifiable {
    let id: ToasttyTranscriptRowID
}

struct ToasttyToolBatchActivity: Equatable {
    let id: ToasttyTranscriptRowID
    let lastSequence: UInt64

    static func make(from blocks: [ToasttyTranscriptBlock]) -> [Self] {
        blocks.compactMap { block in
            guard case .toolBatch(let rows) = block.content,
                  let lastSequence = rows.last?.id.sequence else { return nil }
            return Self(id: block.id, lastSequence: lastSequence)
        }
    }
}

struct ToasttyToolBatchDisclosureState: Equatable {
    private(set) var expandedIDs: Set<ToasttyTranscriptRowID> = []
    private var explicitlyCollapsedIDs: Set<ToasttyTranscriptRowID> = []
    private var lastSequenceByID: [ToasttyTranscriptRowID: UInt64] = [:]
    private var isInitialized = false

    func isExpanded(_ id: ToasttyTranscriptRowID) -> Bool {
        expandedIDs.contains(id)
    }

    mutating func toggle(_ id: ToasttyTranscriptRowID) {
        if expandedIDs.remove(id) != nil {
            explicitlyCollapsedIDs.insert(id)
        } else {
            expandedIDs.insert(id)
            explicitlyCollapsedIDs.remove(id)
        }
    }

    mutating func reconcile(
        activity: [ToasttyToolBatchActivity],
        revision: ToasttyTranscriptRevision
    ) {
        let current = activity.reduce(into: [ToasttyTranscriptRowID: UInt64]()) { values, batch in
            values[batch.id] = batch.lastSequence
        }
        let currentIDs = Set(current.keys)

        guard isInitialized else {
            isInitialized = true
            lastSequenceByID = current
            return
        }

        switch revision {
        case .initial, .rebuilt:
            expandedIDs.removeAll(keepingCapacity: true)
            explicitlyCollapsedIDs.removeAll(keepingCapacity: true)
        case .appended:
            for (id, lastSequence) in current {
                let isNewOrGrowing = lastSequenceByID[id].map { lastSequence > $0 } ?? true
                if isNewOrGrowing, explicitlyCollapsedIDs.contains(id) == false {
                    expandedIDs.insert(id)
                }
            }
        case .prepended, .metadataOnly:
            break
        }

        expandedIDs.formIntersection(currentIDs)
        explicitlyCollapsedIDs.formIntersection(currentIDs)
        lastSequenceByID = current
    }
}

struct ToasttyToolBatchCard: View {
    let blockID: ToasttyTranscriptRowID
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

// TODO: Remove the legacy sheet and selection model after the inline flow is
// verified on a physical device. They intentionally have no invocation path.
struct ToasttyToolActivitySheet: View {
    @Environment(\.dismiss) private var dismiss

    let rows: [ToasttyTranscriptRow]

    private var callCount: Int {
        Set(rows.compactMap(\.toolCallID)).count
    }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "Tool details unavailable",
                        systemImage: "wrench.and.screwdriver",
                        description: Text("This tool activity is no longer in the transcript.")
                    )
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(rows) { row in
                                ToasttyToolEventRow(row: row)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(ToasttyDesignTokens.background)
            .navigationTitle(callCount == 1 ? "1 Tool Call" : "\(callCount) Tool Calls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ToasttyDesignTokens.elevatedSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("toastty-mobile-tool-activity-done")
                }
            }
        }
        .accessibilityIdentifier("toastty-mobile-tool-activity-sheet")
        .tint(ToasttyDesignTokens.amber)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(ToasttyDesignTokens.background)
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
