import SwiftUI
import ToasttyMobileDomain
import UIKit

/// The conversation header's details popover: what the inline navigation bar
/// truncates or leaves out, laid out like the session list's long-press card.
/// Values wrap rather than truncate, and the path is copyable.
struct ToasttyConversationDetailsView: View {
    let conversation: MobileConversation
    /// The parent of a task space, so the workspace reads as its full path.
    let parentWorkspaceTitle: String?
    let freshness: LiveProjectionFreshness

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var copiedPath = false
    @State private var contentHeight: CGFloat?

    var body: some View {
        // The popover asks for the card's full height; when accessibility
        // type sizes make that taller than the screen, the popover shrinks
        // and the card scrolls.
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 320)
        // Ideal, not fixed: a fixed height would overflow a clamped popover
        // and push the title off screen.
        .frame(idealHeight: contentHeight, maxHeight: contentHeight)
        .background(ToasttyDesignTokens.elevatedSurface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toastty-conversation-details")
        .onChange(of: conversation.cwd) { copiedPath = false }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(conversation.title)
                .font(.headline)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("toastty-conversation-details-title")
            Rectangle()
                .fill(ToasttyDesignTokens.divider)
                .frame(height: 1)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                fact("status", statusText)
                if conversation.turnElapsed != nil, freshness == .live {
                    tickingFact("elapsed", every: 1) {
                        conversation.elapsedTurnLabel(atMonotonicTime: ProcessInfo.processInfo.systemUptime) ?? ""
                    }
                }
                if !conversation.displayAge.isEmpty {
                    tickingFact("updated", every: 60) { conversation.displayAge }
                }
                if let lastTurn = conversation.lastTurnLabel {
                    fact("last turn", lastTurn)
                }
                if let workspacePath {
                    fact("workspace", workspacePath)
                }
                if let cwd = conversation.cwd {
                    pathRow(cwd)
                }
                fact("agent", agentText)
                if conversation.isFlaggedForLater {
                    fact("flagged", "for later")
                }
            }
        }
        .padding(14)
    }

    private var statusText: String {
        let presentation = ToasttySessionStatusPresentation(
            bucket: conversation.state.bucket,
            freshness: freshness
        )
        return presentation.isVisible ? presentation.label : conversation.state.accessibilityLabel
    }

    private var workspacePath: String? {
        let parts = [parentWorkspaceTitle, conversation.workspaceTitle, conversation.workspaceTabTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " › ")
    }

    private var agentText: String {
        let profile = ToasttySessionExecutionProfilePresentation(
            profile: conversation.executionProfile,
            isLastReported: freshness != .live
        )
        return [conversation.agent.displayName, profile?.text]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The full path, never truncated, with a Copy button beside it.
    private func pathRow(_ cwd: String) -> some View {
        // At accessibility type sizes Copy moves under the path so the path
        // keeps the full width.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return factRow("path") {
            layout {
                Text(cwd)
                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("toastty-conversation-details-path")
                Button(copiedPath ? "Copied" : "Copy") {
                    UIPasteboard.general.string = cwd
                    copiedPath = true
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.amberText)
                .buttonStyle(.plain)
                .accessibilityLabel(copiedPath ? "Path copied" : "Copy path")
                .accessibilityIdentifier("toastty-conversation-details-copy-path")
            }
        }
        .task(id: copiedPath) {
            guard copiedPath else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copiedPath = false
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        factRow(label) { factValue(value, label: label) }
    }

    /// A clock-derived value that refreshes while the popover stays open.
    private func tickingFact(
        _ label: String,
        every interval: TimeInterval,
        _ value: @escaping () -> String
    ) -> some View {
        factRow(label) {
            TimelineView(.periodic(from: .now, by: interval)) { _ in
                factValue(value(), label: label)
            }
        }
    }

    /// Label beside value in the grid; at accessibility type sizes the label
    /// sits above a full-width value, which the grid spans as one cell.
    @ViewBuilder
    private func factRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        let labelText = Text(label).foregroundStyle(ToasttyDesignTokens.mutedText)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                labelText
                value()
            }
            .font(.caption.monospaced())
        } else {
            GridRow {
                labelText
                value()
            }
            .font(.caption.monospaced())
        }
    }

    private func factValue(_ value: String, label: String) -> some View {
        Text(value)
            .foregroundStyle(ToasttyDesignTokens.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier("toastty-conversation-details-\(label.replacingOccurrences(of: " ", with: "-"))")
    }
}
