import SwiftUI

struct ToasttyToolBatchSelection: Identifiable {
    let id: ToasttyTranscriptRowID
}

struct ToasttyToolBatchCard: View {
    let blockID: ToasttyTranscriptRowID
    let rows: [ToasttyTranscriptRow]
    let showDetails: () -> Void

    private var callCount: Int {
        Set(rows.compactMap(\.toolCallID)).count
    }

    var body: some View {
        Button(action: showDetails) {
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
                    Text("View details")
                        .font(.caption2.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(ToasttyDesignTokens.raisedSurface)
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(ToasttyDesignTokens.border)
            }
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(callCount == 1 ? "1 tool call" : "\(callCount) tool calls")
        .accessibilityHint("Opens tool details")
        .accessibilityIdentifier(
            "toastty-mobile-transcript-tool-\(blockID.accessibilitySuffix)"
        )
    }
}

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
                                toolEvent(row)
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

    private func toolEvent(_ row: ToasttyTranscriptRow) -> some View {
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
            RoundedRectangle(cornerRadius: 10)
                .stroke(ToasttyDesignTokens.border)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
