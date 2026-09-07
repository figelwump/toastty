import CoreState
import Foundation
import SwiftUI

/// Resolved header presentation for a terminal's agent-read activity.
enum TerminalReadActivityIndicatorState: Equatable {
    /// No other session has read this pane and reads are allowed.
    case hidden
    /// At least one live session has read this pane.
    case idle
    /// The user marked the pane private; shown regardless of readers.
    case privateToAgents

    static func resolve(allowsAgentReads: Bool, hasReaders: Bool) -> Self {
        if allowsAgentReads == false {
            return .privateToAgents
        }
        return hasReaders ? .idle : .hidden
    }
}

enum TerminalReadActivityTooltip {
    static let privateText = "Private: agents cannot read this terminal"

    /// One line per reader, most recent first.
    static func lines(
        readers: [TerminalReadActivityReader],
        shortcutNumberForSession: (String) -> Int?,
        now: Date
    ) -> [String] {
        readers.map { reader in
            var subject = reader.label
            if let shortcutNumber = shortcutNumberForSession(reader.sessionID),
               let label = DisplayShortcutConfig.panelFocusShortcutLabel(for: shortcutNumber) {
                subject += " (\(label))"
            }
            let reads = reader.readCount == 1 ? "1 read" : "\(reader.readCount) reads"
            return "Read by \(subject) · \(reads) · last \(relativeAge(from: reader.lastReadAt, to: now))"
        }
    }

    static func text(
        readers: [TerminalReadActivityReader],
        shortcutNumberForSession: (String) -> Int?,
        now: Date = Date()
    ) -> String {
        lines(readers: readers, shortcutNumberForSession: shortcutNumberForSession, now: now)
            .joined(separator: "\n")
    }

    static func relativeAge(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date).rounded()))
        switch seconds {
        case 0..<5:
            return "just now"
        case 5..<60:
            return "\(seconds) s ago"
        case 60..<3600:
            return "\(seconds / 60) min ago"
        case 3600..<86_400:
            return "\(seconds / 3600) h ago"
        default:
            return "\(seconds / 86_400) d ago"
        }
    }
}

/// Menu items shared by the header context menu and the glyph click menu.
struct TerminalAgentReadMenuItems: View {
    let allowsAgentReads: Bool
    let setAllowsAgentReads: (Bool) -> Void
    let closePanel: () -> Void

    var body: some View {
        Toggle(
            "Allow Agents to Read This Terminal",
            isOn: Binding(
                get: { allowsAgentReads },
                set: { setAllowsAgentReads($0) }
            )
        )

        Divider()

        Button("Close Panel", role: .destructive) {
            closePanel()
        }
    }
}

/// Header glyph: a muted eye once another session has read this terminal,
/// which flashes to the accent color on every read and clears when the last
/// reader session ends. An eye-slash marks a pane the user made private.
struct TerminalReadActivityIndicator: View {
    @ObservedObject var model: TerminalReadActivityModel
    let allowsAgentReads: Bool
    let appIsActive: Bool
    let shortcutNumberForSession: (String) -> Int?
    let setAllowsAgentReads: (Bool) -> Void
    let closePanel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFlashing = false
    @State private var settleTask: Task<Void, Never>?
    /// Read count the idle glyph was last shown for. The glyph mounts only
    /// after the first read changes the count, so `onChange` alone misses it.
    @State private var lastFlashedReadCount = 0

    /// How long the eye stays accent-colored with the "Read by" label after a
    /// read. Long enough to read the label; repeated polls keep extending it.
    private static let flashDurationNanoseconds: UInt64 = 4_000_000_000

    private var state: TerminalReadActivityIndicatorState {
        .resolve(allowsAgentReads: allowsAgentReads, hasReaders: model.hasReaders)
    }

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .idle:
            menu {
                HStack(spacing: 4) {
                    glyph(systemName: "eye", tint: idleTint)
                    if isFlashing, let reader = model.mostRecentReader {
                        Text("Read by \(reader.label)")
                            .font(ToastyTheme.fontWorkspaceSessionChip)
                            .foregroundStyle(idleTint)
                            .tint(idleTint)
                            .lineLimit(1)
                            .fixedSize()
                            .transition(.opacity)
                    }
                }
            }
            .accessibilityLabel("Read by agents")
            .accessibilityIdentifier("panel.header.read-activity.\(model.panelID.uuidString)")
            .help(
                TerminalReadActivityTooltip.text(
                    readers: model.readers,
                    shortcutNumberForSession: shortcutNumberForSession
                )
            )
            .onAppear {
                if model.totalReadCount > lastFlashedReadCount {
                    flash()
                }
            }
            .onChange(of: model.totalReadCount) { _, _ in
                flash()
            }
            .onDisappear {
                settleTask?.cancel()
                settleTask = nil
                isFlashing = false
            }
        case .privateToAgents:
            menu {
                glyph(systemName: "eye.slash", tint: mutedTint)
            }
            .accessibilityLabel("Private to agents")
            .accessibilityIdentifier("panel.header.read-private.\(model.panelID.uuidString)")
            .help(TerminalReadActivityTooltip.privateText)
            .onAppear {
                // Reads that arrive while private never flashed; do not flash
                // them retroactively when the user allows reads again.
                lastFlashedReadCount = model.totalReadCount
            }
        }
    }

    private func menu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            TerminalAgentReadMenuItems(
                allowsAgentReads: allowsAgentReads,
                setAllowsAgentReads: setAllowsAgentReads,
                closePanel: closePanel
            )
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder
    private func glyph(systemName: String, tint: Color) -> some View {
        let image = Image(systemName: systemName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .tint(tint)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        if reduceMotion {
            image
        } else {
            image.symbolEffect(.bounce, options: .nonRepeating, value: model.totalReadCount)
        }
    }

    private var idleTint: Color {
        if isFlashing {
            return appIsActive ? ToastyTheme.accent : ToastyTheme.accent.opacity(0.55)
        }
        return mutedTint
    }

    private var mutedTint: Color {
        ToastyTheme.sidebarSessionDetailText.opacity(appIsActive ? 0.6 : 0.35)
    }

    private func flash() {
        lastFlashedReadCount = model.totalReadCount
        settleTask?.cancel()
        // Snap to the accent immediately so the read is visible the instant
        // it happens; only the settle back to muted is animated.
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) {
            isFlashing = true
        }
        settleTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.flashDurationNanoseconds)
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) {
                isFlashing = false
            }
            settleTask = nil
        }
    }
}
